# swift_build_support/products/swiftbacktrace.py ------------------*- python -*-
#
# This source file is part of the Swift.org open source project
#
# Copyright (c) 2022 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See https://swift.org/LICENSE.txt for license information
# See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
#
# ----------------------------------------------------------------------------

import os
import platform

from . import cmark
from . import foundation
from . import libcxx
from . import libdispatch
from . import libicu
from . import llbuild
from . import llvm
from . import product
from . import swift
from . import swiftpm
from . import xctest
from .. import shell
from .. import targets


# Build against the current installed toolchain.
class SwiftBacktrace(product.Product):
    @classmethod
    def product_source_name(cls):
        return "swift-backtrace"

    @classmethod
    def is_build_script_impl_product(cls):
        return False

    @classmethod
    def is_before_build_script_impl_product(cls):
        return False

    def run_build_script_helper(self, action, host_target):
        configuration = 'release' if self.is_release() else 'debug'

        package_path = os.path.join(self.source_dir,
                                    '..', 'swift', 'tools', 'swift-backtrace')
        package_path = os.path.abspath(package_path)

        script_path = os.path.join(
            package_path, 'build-script-helper.py')

        # swift-backtrace is installed at '/usr/libexec/swift/swift-backtrace' in
        # the built toolchain.
        install_toolchain_path = self.install_toolchain_path(host_target)
        install_path = os.path.join(install_toolchain_path, 'libexec', 'swift')

        helper_cmd = [
            script_path,
            action,
            '--toolchain', self.native_toolchain_path(host_target),
            '--configuration', configuration,
            '--build-path', self.build_dir,
            '--package-path', package_path,
            '--install-path', install_path,
        ]

        if self.args.verbose_build:
            helper_cmd.append('--verbose')

        shell.call(helper_cmd)

    def should_build(self, host_target):
        return True

    def build(self, host_target):
        self.run_build_script_helper('build', host_target)

    def should_test(self, host_target):
        return self.args.test_swift_backtrace

    def test(self, host_target):
        self.run_build_script_helper('test', host_target)

    def should_install(self, host_target):
        return self.args.install_swift_backtrace

    def install(self, host_target):
        self.run_build_script_helper('install', host_target)

    @classmethod
    def get_dependencies(cls):
        return [cmark.CMark,
                llvm.LLVM,
                libcxx.LibCXX,
                libicu.LibICU,
                swift.Swift,
                libdispatch.LibDispatch,
                foundation.Foundation,
                xctest.XCTest,
                llbuild.LLBuild,
                swiftpm.SwiftPM]
