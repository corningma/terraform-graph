# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for tfgraph-server (single-file binary, embeds static frontend)
#
# Usage:
#   cd <repo-root>
#   pip install -r requirements-build.txt -r server/requirements.txt
#   pyinstaller server/build.spec --clean

block_cipher = None

# 把 server/static 嵌入到运行时虚拟文件系统，运行时通过 sys._MEIPASS 访问
datas = [
    ('server/static',  'static'),
]

a = Analysis(
    ['server/app.py'],
    pathex=['server'],
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
