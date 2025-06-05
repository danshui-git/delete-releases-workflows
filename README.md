# Function description / 功能说明

此仓库代码由《[delete-releases-workflows](https://github.com/ophub/delete-releases-workflows)》仓库代码修改而成

这个 Actions 可以删除指定仓库的 Releases 和 Workflows 运行记录。

## Instructions / 使用说明

```yaml
    steps:
    - name: 检出仓库
      uses: actions/checkout@v4

    - name: 清理releases和workflows
      uses: danshui-git/delete-releases-workflows@main
      with:
        delete_releases: true
        delete_workflows: true
        gh_token: ${{ secrets.REPO_TOKEN }}
```

```yaml

    使用说明：

    - name: 清理releases和workflows
      uses: danshui-git/delete-releases-workflows@main
      with:
        delete_releases: true                  清理releases开关，必须存在，如果不开就写false
        prerelease_option: all                 设置清理releases是否区分预发行版本
        releases_keep_keyword: targz/Update    清理releases时候保留关键字符名称的tags不清理（targz/Update 改成你需要的关键字符,不需要的就不附加此项）
        releases_keep_latest: 90               清理releases时候排除关键字符tags外，再保留N个时间靠前的发布不清理
        delete_tags: true                      清理releases时候清理tags，一般都开启同步清理的
        max_releases_fetch: 200                一次最多检查多少个releases，进行清理，设置太多的话，清理时间过长，或者会出现超时情况，按100倍数增加，最高可以设置1000（比如100、200、300...800、900、1000）

        delete_workflows: true                清理workflows开关，必须存在，如果不开就写false
        workflows_keep_keyword: lede          清理workflows时候保留关键字符名称的runs不清理（lede 改成你需要的关键字符,不需要的就不附加此项）
        workflows_keep_latest: 90             清理workflows时候排除关键字符runs外，再保留N个时间靠前的runs不清理
        max_workflows_fetch: 200              一次最多检查多少个workflows，进行清理，设置太多的话，清理时间过长，或者会出现超时情况，按100倍数增加，最高可以设置1000（比如100、200、300...800、900、1000）
        repo: ${{ github.repository }}        清理仓库设置，默认为您启动本程序的自身仓库
        gh_token: ${{ secrets.REPO_TOKEN }}   GITHUB_TOKEN，仓库密匙，必须存在
```

## Setting instructions / 设置说明

You can configure the deletion settings in the delete.yml file with the following options:

您可以在 清理releases和workflows 选项配置：

| Key / 选项               | Required   | Description / 说明                       |
| ----------------------- | ---------- | ---------------------------------------- |
| delete_releases         | 必选项 | 设置是否删除 releases 文件（选项：`true`/`false`），必需附加值，没此值会报错退出。 |
| prerelease_option       | 可选项 | 设置是否区分预发行版本（选项：`all`/`true`/`false`）。`all`表示全部类型，`true`/`false`代表仅删除标记为此类型的 releases 文件。默认为 `all`。 |
| releases_keep_latest    | 可选项 | 设置保留几个最新的 Releases 版本（`整数`。如：5，别整带小数点的），设置为 `0` 表示全部删除，默认保留 `90` 个。 |
| releases_keep_keyword   | 可选项   | 设置需要保留的 Releases 的 tags `关键字`，多个关键字使用 `/` 分割（例如：`book/tool`），默认值 `无`。 |
| delete_tags             | 可选项   | 设置是否删除与 Releases 关联的 tags（选项：`true`/`false`），默认为 `true`。 |
| max_releases_fetch   | 可选项   | 一次最多检查多少个releases，进行清理，设置太多的话，清理时间过长，或者会出现超时情况，按100倍数增加，最高可以设置1000（比如100、200、300...800、900、1000），默认值 `200`。 |
| delete_workflows        | 必选项 | 设置是否删除 workflows 运行记录（选项：`true`/`false`），必需附加值，没此值会报错退出。 |
| workflows_keep_latest      | 可选项 | 设置保留时间靠前的 workflows 记录（`整数`。如：30，别整带小数点的），设置为 `0` 表示全部删除。默认为 `90` 个。 |
| workflows_keep_keyword  | 可选项   | 设置需要保留的 workflows 运行记录的名称`关键字`，多个关键字使用 `/` 分割（例如：`book/tool`），默认值 `无`。 |
| max_workflows_fetch   | 可选项   | 一次最多检查多少个workflow，进行清理，设置太多的话，清理时间过长，或者会出现超时情况，按100倍数增加，最高可以设置1000（比如100、200、300...800、900、1000），默认值 `200`。 |
| out_log                 | 可选项   | 设置是否输出详细的 json 日志（选项：`true`/`false`），默认值 `false`。 |
| repo                    | 可选项   | 设置执行操作的 `<owner>/<repo>` ，默认为`当前仓库`。 |
| gh_token                | 必须项 | Set the [GITHUB_TOKEN](https://docs.github.com/en/actions/security-guides/automatic-token-authentication) password for executing the delete operation.<br />设置执行删除操作的 [GITHUB_TOKEN](https://docs.github.com/zh/actions/security-guides/automatic-token-authentication#about-the-github_token-secret) 口令，必需附加值，没此值会报错退出 |


## License / 许可

The delete-releases-workflows © OPHUB is licensed under [GPL-2.0](https://github.com/ophub/delete-releases-workflows/blob/main/LICENSE)
