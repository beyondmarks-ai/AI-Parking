"""Private, immutable snapshots. A stored OCR observation is not a violation."""
import asyncio
from collections import deque
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
from io import BytesIO
import os
import time
from uuid import UUID

from azure.core.exceptions import AzureError, HttpResponseError, ResourceNotFoundError
from azure.storage.blob import BlobClient, ContentSettings
from fastapi import APIRouter, Header, HTTPException, Request
from PIL import Image, UnidentifiedImageError

from foundry_ocr import PLATE

router = APIRouter()
MAX_BYTES = 4 * 1024 * 1024
_slots = asyncio.Semaphore(2)
_requests = deque()


def validate_zone(source: str, aspect: float) -> str:
    """Validate client calibration, not the client's parking/plate claim."""
    try:
        zone = json.loads(source)
        points = zone['points']
        ratio = zone['aspect']
        if (zone['version'] != 1 or not isinstance(ratio, (int, float)) or
                isinstance(ratio, bool) or not math.isfinite(ratio) or
                not .2 <= ratio <= 5 or abs(aspect / ratio - 1) >= .01 or
                not isinstance(points, list) or len(points) != 4):
            raise ValueError()
        for point in points:
            if (not isinstance(point, list) or len(point) != 2 or any(
                    not isinstance(v, (int, float)) or isinstance(v, bool) or
                    not math.isfinite(v) or not 0 <= v <= 1 for v in point)):
                raise ValueError()
        direction, area = None, 0.0
        for i in range(4):
            a, b, c = points[i], points[(i + 1) % 4], points[(i + 2) % 4]
            cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            if abs(cross) < .00001 or (direction is not None and cross * direction < 0):
                raise ValueError()
            direction = cross
            area += a[0] * b[1] - b[0] * a[1]
        if abs(area) / 2 < .01:
            raise ValueError()
        return json.dumps({'version': 1, 'aspect': ratio, 'points': points}, separators=(',', ':'))
    except (ValueError, TypeError, KeyError, ZeroDivisionError) as error:
        raise HTTPException(422, 'Invalid bay calibration for this snapshot') from error


def store_snapshot(capture_id: UUID, data: bytes, metadata: dict):
    url = os.getenv('CAPTURE_STORAGE_URL', '').rstrip('/')
    sas = os.getenv('CAPTURE_STORAGE_SAS', '')
    if not url.startswith('https://') or not sas:
        raise HTTPException(503, 'Snapshot storage is not configured')
    # Container/destination are server controlled, never supplied by the phone.
    with BlobClient(account_url=url, container_name='plate-snapshots',
                    blob_name=f'{capture_id}.jpg', credential=sas,
                    connection_timeout=5, read_timeout=10, retry_total=0) as blob:
        def check_existing():
            existing = blob.get_blob_properties().metadata
            if any(existing.get(key) != value for key, value in metadata.items()):
                raise HTTPException(409, 'Capture ID already belongs to another snapshot')
        try:
            check_existing()
        except ResourceNotFoundError:
            try:
                blob.upload_blob(data, overwrite=False, metadata=metadata,
                                 content_settings=ContentSettings(
                                     content_type='image/jpeg',
                                     content_disposition=f'attachment; filename="{capture_id}.jpg"'))
            except HttpResponseError as upload_error:
                # With a create-only SAS, racing duplicate PUTs may return 403
                # instead of BlobAlreadyExists. Verify the immutable existing
                # object without granting overwrite permission.
                try:
                    check_existing()
                except ResourceNotFoundError:
                    raise upload_error
    return {'id': str(capture_id), 'plate': metadata['plate'],
            'captured_at': metadata['captured_at'], 'saved': True}


@router.put('/api/v1/captures/{capture_id}')
async def archive_capture(capture_id: UUID, request: Request,
                          x_plate_number: str = Header(max_length=16),
                          x_captured_at: datetime = Header(),
                          x_ocr_provider: str = Header(max_length=64),
                          x_parking_zone: str | None = Header(default=None, max_length=2048),
                          x_parking_decision: str | None = Header(default=None, max_length=16),
                          x_fine_amount: int | None = Header(default=None, ge=0, le=99999)):
    if not PLATE.fullmatch(x_plate_number):
        raise HTTPException(422, 'A confirmed plate number is required')
    if (x_captured_at.tzinfo is None or
            not datetime.now(timezone.utc) - timedelta(days=7) <= x_captured_at
            <= datetime.now(timezone.utc) + timedelta(minutes=5)):
        raise HTTPException(422, 'Capture time must include timezone and be recent')
    if not x_ocr_provider or not x_ocr_provider.isascii() or any(
            ord(c) < 32 or ord(c) == 127 for c in x_ocr_provider):
        raise HTTPException(422, 'Invalid OCR provider')
    if request.headers.get('content-type', '').split(';')[0].lower() != 'image/jpeg':
        raise HTTPException(415, 'Send a JPEG snapshot')
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > MAX_BYTES:
            raise HTTPException(413, 'Snapshot exceeds 4 MB')
    try:
        with Image.open(BytesIO(data)) as image:
            if image.format != 'JPEG' or image.width * image.height > 8_000_000:
                raise HTTPException(415, 'Invalid JPEG dimensions')
            zone = validate_zone(x_parking_zone, image.width / image.height) if x_parking_zone else None
            image.verify()
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as error:
        raise HTTPException(415, 'Invalid JPEG snapshot') from error
    now = time.monotonic()
    while _requests and _requests[0] < now - 60:
        _requests.popleft()
    if len(_requests) >= 12 or _slots.locked():
        raise HTTPException(429, 'Snapshot storage busy; retry later')
    _requests.append(now)
    metadata = {'plate': x_plate_number,
                'captured_at': x_captured_at.astimezone(timezone.utc).isoformat(),
                'ocr_provider': x_ocr_provider,
                'sha256': hashlib.sha256(data).hexdigest(),
                'review_status': 'client_ocr_confirmed_not_reviewed'}
    if zone:
        metadata['parking_zone'] = zone
        metadata['zone_observation'] = 'client_plate_in_bay_needs_review'
    if x_parking_decision is not None or x_fine_amount is not None:
        if not zone or not ((x_parking_decision == 'inside' and x_fine_amount is not None and x_fine_amount > 0)
                            or (x_parking_decision == 'outside' and x_fine_amount == 0)):
            raise HTTPException(422, 'Inconsistent parking decision')
        metadata['zone_observation'] = 'client_image_analysis_' + x_parking_decision
        metadata['fine_amount'] = str(x_fine_amount)
        metadata['review_status'] = 'prototype_display_decision_not_legal_notice'
    try:
        async with _slots:
            return await asyncio.to_thread(store_snapshot, capture_id, bytes(data), metadata)
    except AzureError as error:
        # Never return provider URLs/SAS tokens or credentials to the client.
        raise HTTPException(502, 'Private snapshot storage unavailable') from error
