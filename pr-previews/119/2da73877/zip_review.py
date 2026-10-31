#!/usr/bin/env python3

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

board = Path(__file__).resolve().parent
patterns = (
    "*.kicad_sch *.kicad_pcb *.kicad_pro *.kicad_dru *-lib-table "
    "*.pdf *.rpt *.json *.csv *.net *.xml *.md *.txt *.svg *.png *.jpg *.dxf "
    "symbols/**/* footprints/**/* 3d/**/* pdfs/**/* production/**/* "
    "../RP2350_80QFN_minimal/MCU_RaspberryPi_RP2350.kicad_sym"
)
with ZipFile(board / "board_review.zip", "w", ZIP_DEFLATED) as archive:
    for path in sorted(
        {p.resolve() for pattern in patterns.split() for p in board.glob(pattern)}
    ):
        if path.is_file() and not any(
            p.startswith((".", "~")) for p in path.relative_to(board.parent).parts
        ):
            archive.write(path, path.relative_to(board.parent))
print(f"Created {board / 'board_review.zip'}")
