# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for tfgraph-agent (single-file binary)
#
# 该 spec 文件位于 agent/ 目录下，PyInstaller 会以 spec 所在目录解析相对路径，
# 因此脚本路径相对 spec 同级（不要再加 "agent/" 前缀）。
#
# Usage (从仓库根目录执行):
#   pip install -r requirements-build.txt -r agent/requirements.txt
#   pyinstaller agent/build.spec --clean --noconfirm

import os

block_cipher = None

AGENT_DIR = SPECPATH  # 即 <repo>/agent

a = Analysis(
    [os.path.join(AGENT_DIR, 'tfgraph_agent.py')],
    pathex=[AGENT_DIR],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'numpy', 'pandas', 'PIL'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='tfgraph-agent',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
