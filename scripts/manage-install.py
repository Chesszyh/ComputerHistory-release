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



def app_program(bundle, name):
    return bundle / 'Contents/MacOS' / name


def preserve_helper(installed, candidate):
    old = app_program(installed, 'computer-history-credentials')
    new = app_program(candidate, 'computer-history-credentials')
    if not old.exists():
        return
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', installed)
    def signature(path):
        result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=2', '-r-', str(path)], capture_output=True, text=True, check=True)
        return result.stdout + result.stderr
    details = signature(new)
    old_details = signature(old)
    temporary = 'Signature=adhoc' in details and 'Signature=adhoc' in old_details
    if temporary:
        identifier = 'Identifier=xyz.chesszyh.computer-history.credentials'
        if identifier not in details.splitlines() or identifier not in old_details.splitlines():
            raise ValueError('密钥助手标识不匹配，尚未替换程序。')
    else:
        requirements = [line.lstrip('# ').split('=>', 1)[1].strip() for line in details.splitlines()
                        if line.lstrip('# ').startswith('designated =>')]
        if not requirements:
            raise ValueError('无法识别密钥助手签名要求，尚未替换程序。')
        run('/usr/bin/codesign', '--verify', '-R', '=' + requirements[0], old)
    old_version = subprocess.check_output([str(old), '--protocol-version'], text=True).strip()
    new_version = subprocess.check_output([str(new), '--protocol-version'], text=True).strip()
    if old_version != new_version:
        raise ValueError('密钥助手协议已变化，需要显式迁移，尚未替换程序。')
    # The helper is independent of activity code. Keeping it avoids self-signed partition hash churn.
    subprocess.run(['/bin/cp', '-p', str(old), str(new)], check=True)
    if temporary:
        # Ad-hoc bundles seal nested code by content; retain the authorized helper and renew that seal.
        run('/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
            'xyz.chesszyh.computer-history.menubar', candidate)


def manage_app(source, target, root, launch_agents, uninstall=False):
    if target.is_symlink():
        raise ValueError('安装目录不能是符号链接。')
    if target.exists():
        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'xyz.chesszyh.computer-history.menubar':
            raise ValueError('目标不是 ComputerHistory。')
    if not uninstall:
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', source)
        run(app_program(source, 'computer-history'), '--help')
    elif not target.exists():
        raise ValueError('未找到 ComputerHistory.app。')
    domain = f'gui/{os.getuid()}'
    labels = [LABEL, 'xyz.chesszyh.computerhistory.collector']
    states = []
    for label in labels:
        path = launch_agents / (label + '.plist')
        original = path.read_bytes() if path.exists() else None
        states.append((label, path, original, launchctl('print', domain + '/' + label).returncode == 0))
    stage = Path(tempfile.mkdtemp(prefix='.ComputerHistory-', dir=target.parent))
    previous = stage / 'ComputerHistory.app'
    candidate = stage / 'candidate.app'
    replaced = False
    services_touched = False
    try:
        if not uninstall:
            subprocess.run(['/usr/bin/ditto', str(source), str(candidate)], check=True)
            preserve_helper(target, candidate)
            # Replacing a helper with the same designated requirement preserves the outer bundle seal.
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', candidate)
        services_touched = True
        for label, path, original, loaded in states:
            if loaded and launchctl('bootout', domain + '/' + label).returncode:
                raise RuntimeError('无法停止登录服务：' + label)
        binary = target if uninstall else source
        run(app_program(binary, 'computer-history-menubar'), '--stop', '--out', root)
        run(app_program(binary, 'computer-history'), '--stop', '--out', root)
        deadline = time.monotonic() + 20
        while running_programs():
            if time.monotonic() > deadline:
                raise RuntimeError('旧进程未退出，尚未替换程序。')
            time.sleep(.1)
        if target.exists():
            target.rename(previous)
        replaced = True
        if not uninstall:
            candidate.rename(target)
        for label, path, original, loaded in states:
            if uninstall:
                path.unlink(missing_ok=True)
            elif original:
                value = plistlib.loads(original)
                if value.get('Label') != label:
                    raise ValueError('登录项 Label 不匹配。')
                arguments = value['ProgramArguments']
                arguments[0] = str(app_program(target, 'computer-history-menubar' if label == LABEL else 'computer-history'))
                value.pop('Program', None)
                path.write_bytes(plistlib.dumps(value))
                if loaded and launchctl('bootstrap', domain, path).returncode:
                    raise RuntimeError('无法恢复登录服务：' + label)
        print('已卸载应用，数据与钥匙串已保留。' if uninstall else f'已安装到 {target}')
    except Exception:
        if services_touched:
            for label, path, original, loaded in states:
                launchctl('bootout', domain + '/' + label)
        if replaced:
            if target.exists():
                shutil.rmtree(target)
            if previous.exists():
                previous.rename(target)
        for label, path, original, loaded in states:
            if original is not None:
                path.write_bytes(original)
                if loaded and services_touched:
                    result = launchctl('bootstrap', domain, path)
                    if result.returncode:
                        print('旧服务恢复失败：' + label)
        raise
    finally:
        shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'uninstall'])
    parser.add_argument('--out', type=Path, default=Path.home() / '.computer-history', help='Existing data directory')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    source_app = here / 'ComputerHistory.app'
    if here.name == 'Resources' and here.parent.name == 'Contents':
        source_app = here.parent.parent
    bundled = source_app.exists()
    target = Path.home() / ('Applications/ComputerHistory.app' if bundled else 'Applications/ComputerHistory')
    target.parent.mkdir(parents=True, exist_ok=True)
    # Serialize installers without leaving a lock inside the directory being replaced.
    with (target.parent / '.ComputerHistory-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if bundled:
            manage_app(source_app, target, args.out.expanduser().absolute(),
                       Path.home() / 'Library/LaunchAgents', args.action == 'uninstall')
        else:
            manage(here, target, args.out.expanduser().absolute(),
                   Path.home() / f'Library/LaunchAgents/{LABEL}.plist', args.action == 'uninstall')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f'安装操作失败：{error}')
