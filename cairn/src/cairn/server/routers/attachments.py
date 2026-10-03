from __future__ import annotations

import sqlite3
from pathlib import PurePosixPath

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

from cairn.server.db import attachments_root, get_conn
from cairn.server.models import Attachment
from cairn.server.services import get_project_or_404, next_attachment_id, utcnow

router = APIRouter(tags=["attachments"])

_CHUNK_SIZE = 1024 * 1024


def _safe_filename(filename: str) -> str:
    # Strip any directory components so uploads cannot escape the project directory.
    name = PurePosixPath(filename.replace("\\", "/")).name
    if name in ("", ".", ".."):
        raise HTTPException(400, "filename must be a plain file name")
    return name


def _attachment_path(project_id: str, attachment_id: str, filename: str):
    return attachments_root() / project_id / f"{attachment_id}_{filename}"


def _get_attachment_or_404(conn: sqlite3.Connection, project_id: str, attachment_id: str) -> sqlite3.Row:
    row = conn.execute(
        "SELECT * FROM attachments WHERE id = ? AND project_id = ?",
        (attachment_id, project_id),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "Attachment not found")
    return row


@router.post(
    "/projects/{project_id}/attachments",
    response_model=Attachment,
    status_code=201,
)
async def upload_attachment(project_id: str, request: Request, filename: str):
    name = _safe_filename(filename)
    with get_conn() as conn:
        get_project_or_404(conn, project_id)
        aid = next_attachment_id(conn, project_id)
        now = utcnow()

        path = _attachment_path(project_id, aid, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        size = 0
        try:
            with open(path, "wb") as handle:
                async for chunk in request.stream():
                    handle.write(chunk)
                    size += len(chunk)
        except Exception:
            path.unlink(missing_ok=True)
            raise

        conn.execute(
            "INSERT INTO attachments (id, project_id, filename, size, created_at) VALUES (?, ?, ?, ?, ?)",
            (aid, project_id, name, size, now),
        )
        return Attachment(id=aid, filename=name, size=size, created_at=now)


@router.get("/projects/{project_id}/attachments", response_model=list[Attachment])
def list_attachments(project_id: str):
    with get_conn() as conn:
        get_project_or_404(conn, project_id)
        rows = conn.execute(
            "SELECT * FROM attachments WHERE project_id = ? ORDER BY created_at",
            (project_id,),
        ).fetchall()
        return [
            Attachment(id=row["id"], filename=row["filename"], size=row["size"], created_at=row["created_at"])
            for row in rows
        ]


@router.get("/projects/{project_id}/attachments/{attachment_id}")
def download_attachment(project_id: str, attachment_id: str):
    with get_conn() as conn:
        get_project_or_404(conn, project_id)
        row = _get_attachment_or_404(conn, project_id, attachment_id)
        path = _attachment_path(project_id, row["id"], row["filename"])
        if not path.is_file():
            raise HTTPException(404, "Attachment file is missing")
        return FileResponse(path, filename=row["filename"])


@router.delete("/projects/{project_id}/attachments/{attachment_id}", status_code=204)
def delete_attachment(project_id: str, attachment_id: str):
    with get_conn() as conn:
        get_project_or_404(conn, project_id)
        row = _get_attachment_or_404(conn, project_id, attachment_id)
        conn.execute(
            "DELETE FROM attachments WHERE id = ? AND project_id = ?",
            (attachment_id, project_id),
        )
        _attachment_path(project_id, row["id"], row["filename"]).unlink(missing_ok=True)
