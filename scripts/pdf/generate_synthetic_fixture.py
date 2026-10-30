#!/usr/bin/env python3
"""Generate original synthetic one-page test material using only Python stdlib.
Authored for Crosscript release preparation on 2026-10-26; AGPL-3.0-only.
No user document, recording, external text, font file or personal metadata is used.
"""
from pathlib import Path

def pdf_bytes():
    stream = b"BT /F1 18 Tf 64 760 Td (Managed PDF translation) Tj /F1 12 Tf 0 -46 Td (The source document remains an independent copy.) Tj 0 -22 Td (Translated results can be opened again from history.) Tj ET\n"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>", b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream"]
    result = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(result))
        result += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(result)
    result += f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode()
    result += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets[1:])
    result += f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return result

def write_fixture(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(pdf_bytes())

if __name__ == '__main__':
    import argparse, hashlib
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists(): parser.error('Choose a new output file.')
    write_fixture(args.output)
    print(hashlib.sha256(args.output.read_bytes()).hexdigest())
