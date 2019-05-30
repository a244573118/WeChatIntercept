# !/bin/bash

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
framework_name="WeChatIntercept"
app_bundle_path="${WeChat_path}/Contents/MacOS"
app_executable_path="${app_bundle_path}/${app_name}"
app_executable_backup_path="${app_executable_path}_backup"
framework_path="${app_bundle_path}/${framework_name}.framework"

# 备份WeChat原始可执行文件
if [ -f "$app_executable_backup_path" ]
then
    rm "$app_executable_path"
    rm -rf "$framework_path"
    mv "$app_executable_backup_path" "$app_executable_path"

    if [ -f "$app_executable_backup_path" ]
    then
	    echo "卸载失败，请到 /Applications/WeChat.app/Contents/MacOS 路径，删除 WeChatIntercept.framework、WeChat 两个文件文件，并将 WeChat_backup 重命名为 WeChat"
    else
	    echo "卸载成功！"
    fi

else
    echo "未发现ZY助手"
fi
