add_swift_target_executable(swift-backtrace BUILD_WITH_STDLIB
  main.swift
  
  INSTALL_IN_COMPONENT stdlib
  COMPILE_FLAGS -parse-as-library)
