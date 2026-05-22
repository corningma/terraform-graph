# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for tfgraph-server (single-file binary, embeds static frontend)
#
# 该 spec 文件位于 server/ 目录下，PyInstaller 会以 spec 所在目录解析相对路径，
# 因此脚本和 datas 都用 spec 同级路径（不要再加 "server/" 前缀）。
#
# Usage (从仓库根目录执行):
#   pip install -r requirements-build.txt -r server/requirements.txt
#   pyinstaller server/build.spec --clean --noconfirm

import os

block_cipher = None

# SPECPATH 是 PyInstaller 注入的全局变量，指向 spec 文件所在目录
SERVER_DIR = SPECPATH  # 即 <repo>/server
REPO_ROOT  = os.path.dirname(SERVER_DIR)

# 把 server/static 嵌入到运行时虚拟文件系统，运行时通过 sys._MEIPASS 访问
datas = [
    (os.path.join(SERVER_DIR, 'static'), 'static'),
]

a = Analysis(
    [os.path.join(SERVER_DIR, 'app.py')],
    pathex=[SERVER_DIR],          # 让 store / parser 等同级模块可被 import
    binaries=[],
    datas=datas,
    hiddenimports=[
        # uvicorn / starlette 内部以字符串方式导入的模块，需显式声明
        'uvicorn.logging',
        'uvicorn.loops.auto',
        'uvicorn.loops.asyncio',
        'uvicorn.protocols.http.auto',
        'uvicorn.protocols.http.h11_impl',
        'uvicorn.protocols.websockets.auto',
        'uvicorn.protocols.websockets.websockets_impl',
        'uvicorn.protocols.websockets.wsproto_impl',
        'uvicorn.lifespan.on',
        'uvicorn.lifespan.off',
    ],
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
    name='tfgraph-server',
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
