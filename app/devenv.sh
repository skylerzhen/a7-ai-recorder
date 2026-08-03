# A7 Flutter toolchain env (project-local). Source before flutter/dart/sdkmanager.
#   source /Users/eddie/Desktop/proj/Hospital/app/devenv.sh
export PATH="$HOME/development/flutter/bin:$PATH"
export JAVA_HOME="$HOME/development/jdk-17.0.19+10/Contents/Home"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
# 国内镜像:首跑 flutter 会从这里拉 Dart SDK / 引擎产物;pub get 走 pub 镜像
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
