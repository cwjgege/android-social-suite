@echo off
set "ANDROID_SOCIAL_HOME=D:\AndroidSocialPhones"
set "ANDROID_AVD_HOME=%ANDROID_SOCIAL_HOME%\android-avd"
set "ANDROID_EMULATOR_HOME=%ANDROID_SOCIAL_HOME%\emulator-home"
set "ADB_VENDOR_KEYS=C:\Users\12694\.android\adbkey"
if not exist "%ANDROID_EMULATOR_HOME%" mkdir "%ANDROID_EMULATOR_HOME%"
start "" "%ANDROID_SOCIAL_HOME%\android-sdk\emulator\emulator.exe" -avd social_avd_soft -no-snapshot-load -accel on -gpu host -no-metrics -http-proxy http://127.0.0.1:10808
