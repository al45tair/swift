#!/usr/bin/env python3

import argparse
import os
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action')
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--package-path", type=str, required=True)
    parser.add_argument("--build-path", type=str, required=True)
    parser.add_argument("--toolchain", type=str, required=True)
    parser.add_argument("--install-path", type=str, required=False)
    parser.add_argument("--configuration", type=str, choices=['debug', 'release'],
                        default='release')
    parser.add_argument('--prefix', type=str, required=False)

    args = parser.parse_args()

    swift_path = os.path.join(args.toolchain, 'bin', 'swift')

    def get_args_for_swift(action, product, extra_args):
        all_args = [
            swift_path, action,
            '--package-path', args.package_path,
            '--scratch-path', args.build_path,
            '--configuration', args.configuration,
        ]
        all_args += extra_args
        if action == 'test':
            all_args += ['--test-product', product]
        else:
            all_args += ['--product', product]
        if args.verbose:
            all_args.append('--verbose')
        return all_args

    def invoke_swift(action, product, extra_args = []):
        subprocess.call(get_args_for_swift(action, product, extra_args))

    def get_binary_path(product):
        cmd = get_args_for_swift('build', product, ['--show-bin-path'])
        return os.path.join(subprocess.check_output(cmd).strip().decode(),
                            'swift-backtrace')

    if args.action == 'build':
        invoke_swift('build', 'swift-backtrace')
    elif args.action == 'test':
        invoke_swift('test', 'swift-backtrace')
    elif args.action == 'install':
        invoke_swift('build', 'swift-backtrace')
        os.makedirs(args.install_path)
        built_binary = get_binary_path('swift-backtrace')
        shutil.copyfile(built_binary,
                        os.path.join(args.install_path, 'swift-backtrace'))

if __name__ == "__main__":
    main()
