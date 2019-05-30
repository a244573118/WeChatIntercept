#!/bin/bash

WeChat_path="/Applications/WeChat.app"

if [ ! -d "$WeChat_path" ]
then
    WeChat_path="/Applications/微信.app"
    if [ ! -d "$WeChat_path" ]
    then
        echo -e "应用程序文件夹中未发现微信"
        exit
    fi
fi

app_name="WeChat"
shell_path="$(dirname "$0")"
framework_name="WeChatIntercept"
app_bundle_path="${WeChat_path}/Contents/MacOS"
app_executable_path="${app_bundle_path}/${app_name}"
app_executable_backup_path="${app_executable_path}_backup"
framework_path="${shell_path}/${framework_name}.framework"
echo framework_path-----$framework_path
if [ ! -w "$WeChat_path" ]
then
    echo -e "为了将ZY助手写入微信, 请输入密码 ： "
    sudo chown -R $(whoami) "$WeChat_path"
fi

if [ ! -f "$app_executable_backup_path" ] || [ -n "$1" -a "$1" = "--force" ]
then

    cp "$app_executable_path" "$app_executable_backup_path"
    result="y"
else
    read -t 150 -p "已安装ZY助手，是否覆盖？[y/n]:" result
fi

if [[ "$result" == 'y' ]]; then
    cp -r $framework_path ${app_bundle_path}
    ${shell_path}/insert_dylib --all-yes "${framework_path}/${framework_name}" "$app_executable_backup_path" "$app_executable_path"
    echo "安装成功！"
fi
