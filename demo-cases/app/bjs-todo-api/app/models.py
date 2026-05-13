"""Pydantic request / response models."""

from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, EmailStr, Field


class UserCreate(BaseModel):
    email: EmailStr
    name: str = Field(min_length=1, max_length=200)


class UserOut(BaseModel):
    id: int
    email: str
    name: str
    created_at: datetime


class TodoCreate(BaseModel):
    user_id: int
    title: str = Field(min_length=1, max_length=500)
    completed: bool = False


class TodoOut(BaseModel):
    id: int
    user_id: int
    title: str
    completed: bool
    created_at: datetime


class HealthResponse(BaseModel):
    status: str
    detail: Optional[str] = None
