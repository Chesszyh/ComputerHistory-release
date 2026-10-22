#!/usr/bin/env python3
"""Install, upgrade or uninstall ComputerHistory in the current user's Applications folder."""
import argparse
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

LABEL = 'xyz.chesszyh.computerhistory.menubar'
FILES = ('computer-history', 'computer-history-menubar', 'LICENSE', 'README.md', 'manage-install.py')
PROGRAMS = FILES[:2]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def launchctl(*args):
    return subprocess.run(['/bin/launchctl', *map(str, args)], capture_output=True)


def running_programs():
    # Only used to wait, never to signal a process based on its name or PID.
    output = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    return [line.strip() for line in output.splitlines() if Path(line.strip()).name in PROGRAMS]


def stop(source, root):
    run(source / 'computer-history-menubar', '--stop', '--out', root)
    run(source / 'computer-history', '--stop', '--out', root)
    deadline = time.monotonic() + 15
    while running_programs():
        if time.monotonic() >= deadline:
            raise RuntimeError('仍有 ComputerHistory 进程。请停止其他数据目录的实例或退出未登记身份的旧版本，再重试；程序尚未替换。')
        time.sleep(.1)


def manage(source, target, root, plist, uninstall=False):
    service = f'gui/{os.getuid()}/{LABEL}'
    domain = f'gui/{os.getuid()}'
    if target.is_symlink():
        raise ValueError('安装目录不能是符号链接。')
    if target.exists() and set(p.name for p in target.iterdir()) != set(FILES):
        raise ValueError('安装目录包含未管理的文件或不是本安装器创建的目录，请先将其移走。')
    if uninstall and not target.exists():
        raise ValueError('未找到本安装器创建的安装目录。')
    if not uninstall:
        for name in FILES:
            if not (source / name).is_file():
                raise ValueError(f'发行包缺少 {name}')
        for name in PROGRAMS:
            run('/usr/bin/codesign', '--verify', '--strict', source / name)
        run(source / 'computer-history', '--help')
    old_plist = plist.read_bytes() if plist.exists() else None
    login = plistlib.loads(old_plist) if old_plist else None
    if login and login.get('Label') != LABEL:
        raise ValueError('登录项 Label 不匹配。')
    loaded = launchctl('print', service).returncode == 0
    stage = Path(tempfile.mkdtemp(prefix='.ComputerHistory-', dir=target.parent))
    backup = stage / 'previous'
    replaced = False
    cleanup = True
    try:
        if not uninstall:
            candidate = stage / 'new'
            candidate.mkdir()
            for name in FILES:
                subprocess.run(["/bin/cp", "-p", str(source / name), str(candidate / name)], check=True)
        if loaded:
            result = launchctl('bootout', service)
            if result.returncode:
                raise RuntimeError('无法卸载正在运行的登录项：' + result.stderr.decode(errors='replace'))
        # The new CLI shares the verified identity/lock protocol with previous versions.
        stop(target if uninstall else source, root)
        if target.exists():
            target.rename(backup)
        replaced = True
        if not uninstall:
            candidate.rename(target)
        if uninstall:
            if plist.exists():
                plist.unlink()
        elif login:
            login['ProgramArguments'] = [str(target / 'computer-history-menubar'), '--out', str(root)]
            login.pop('Program', None)
            plist.write_bytes(plistlib.dumps(login))
            result = launchctl('bootstrap', domain, plist)
            if result.returncode:
                raise RuntimeError('登录项加载失败：' + result.stderr.decode(errors='replace'))
            if launchctl('print', service).returncode:
                raise RuntimeError('无法确认登录项已加载。')
        print('已卸载程序，历史、配置、请求记录和钥匙串凭据已保留。' if uninstall else
              f'已安装到 {target}。采集保持停止，请检查权限后按原有参数启动。')
    except Exception:
        if replaced:
            launchctl('bootout', service)
            if target.exists():
                shutil.rmtree(target)
            if backup.exists():
                try:
                    backup.rename(target)
                except OSError:
                    cleanup = False
                    print(f'旧程序保留在 {backup}，请从该目录恢复。')
                    raise
        if old_plist is not None:
            plist.write_bytes(old_plist)
        if loaded:
            result = launchctl('bootstrap', domain, plist)
            if result.returncode:
                print('旧登录项恢复失败，请在菜单栏中重新启用登录启动。')
        raise
    finally:
        if cleanup:
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'uninstall'])
    parser.add_argument('--out', type=Path, default=Path.home() / '.computer-history', help='Existing data directory')
    args = parser.parse_args()
    target = Path.home() / 'Applications/ComputerHistory'
    target.parent.mkdir(parents=True, exist_ok=True)
    # Serialize installers without leaving a lock inside the directory being replaced.
    with (target.parent / '.ComputerHistory-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manage(Path(__file__).resolve().parent, target, args.out.expanduser().absolute(),
               Path.home() / f'Library/LaunchAgents/{LABEL}.plist', args.action == 'uninstall')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f'安装操作失败：{error}')
