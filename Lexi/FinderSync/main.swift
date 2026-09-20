// appex 引导入口 —— 对应 Xcode 模板的 main.m。
//
// swiftc 对无顶层代码的 executable 会合成空 main() 并立即退出：
// 进程"spawn 成功→15ms 闪退→service inactive"，Finder 侧表现为
// Hub connection 4097。真正的入口必须引导扩展运行循环：
// 读 Info.plist 的 NSExtensionPrincipalClass、实例化、进入 runloop。

import Foundation

@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutableRawPointer?) -> Int32

// Raw pointer: char** vs char*?[] SDK typings differ, the ABI is the same.
NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
