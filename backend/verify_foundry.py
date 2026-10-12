"""Smoke test with generated text, never a live camera capture."""
import asyncio
from io import BytesIO
import os
import subprocess
import sys
import httpx
from PIL import Image, ImageDraw, ImageFont
from foundry_ocr import transcribe


def sample(text='KA01AB1234'):
    image = Image.new('RGB', (600, 140), 'white')
    try:
        font = ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf', 66)
    except OSError:
        font = ImageFont.load_default(size=58)
    ImageDraw.Draw(image).text((30, 30), text, fill='black', font=font)
    buffer = BytesIO()
    image.save(buffer, format='JPEG', quality=95)
    return buffer.getvalue()


async def main():
    if len(sys.argv) > 1:
        async with httpx.AsyncClient(timeout=40) as client:
            for text, expected in [('KA01AB1234', 'KA01AB1234'), ('', None)]:
                response = await client.post(sys.argv[1].rstrip('/') + '/api/v1/ocr/foundry',
                                             content=sample(text), headers={'Content-Type': 'image/jpeg'})
                print('API status:', response.status_code, response.text[:1000])
                response.raise_for_status()
                assert response.json().get('plate') == expected
                assert response.json().get('readable') == (expected is not None)
        return
    key = subprocess.run(['az.cmd', 'cognitiveservices', 'account', 'keys', 'list',
        '-g', 'guardian-ai-rg', '-n', 'guardian-ai-openai-617db5', '--query', 'key1', '-o', 'tsv'],
        capture_output=True, text=True, check=True).stdout.strip()
    os.environ.update(FOUNDRY_ENDPOINT='https://guardian-ai-openai-617db5.openai.azure.com',
                      FOUNDRY_MODEL='guardian-vision', FOUNDRY_API_KEY=key)
    async with httpx.AsyncClient(timeout=25) as client:
        try:
            for text, expected in [('KA01AB1234', 'KA01AB1234'), ('', None)]:
                plate = await transcribe(sample(text), client)
                print('Synthetic image transcription:', plate)
                assert plate == expected
        except httpx.HTTPStatusError as error:
            print('Foundry status:', error.response.status_code, error.response.text[:1200])
            raise SystemExit(1)

if __name__ == '__main__':
    asyncio.run(main())
