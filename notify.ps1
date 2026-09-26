<#
    NightLock notification sender.
    ASCII only on purpose: every message text is passed in by the caller.
    Supported channels: dingtalk, wecom, feishu, qqmail.
#>

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

function Send-JsonPost {
    param([string]$Url, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    return Invoke-RestMethod -Uri $Url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 20
}

function Test-NotifyConfig {
    param($Notify)
    if (-not $Notify) { return '没有通知设置' }
    if (-not $Notify.Enabled) { return '通知未启用' }
    $channel = [string]$Notify.Channel
    if (-not $channel -or $channel -eq 'none') { return '没有选择通知方式' }
    switch ($channel) {
        'dingtalk' { if (-not $Notify.Webhook) { return '钉钉机器人地址是空的' } }
        'wecom'    { if (-not $Notify.Webhook) { return '企业微信机器人地址是空的' } }
        'feishu'   { if (-not $Notify.Webhook) { return '飞书机器人地址是空的' } }
        'qqmail'   {
            if (-not $Notify.MailFrom)   { return '发件邮箱是空的' }
            if (-not $Notify.MailTo)     { return '收件邮箱是空的' }
            if (-not $Notify.MailAuthCode) { return '邮箱授权码是空的' }
        }
        default { return ('不认识的通知方式：' + $channel) }
    }
    return ''
}

function Send-Notify {
    param($Notify, [string]$Subject, [string]$Body)

    $result = [ordered]@{ Ok = $false; Message = '' }

    $problem = Test-NotifyConfig -Notify $Notify
    if ($problem) { $result.Message = $problem; return $result }

    $channel = [string]$Notify.Channel

    try {
        switch ($channel) {
            'dingtalk' {
                $url = [string]$Notify.Webhook
                if ($Notify.Secret) {
                    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $hmac = New-Object System.Security.Cryptography.HMACSHA256
                    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes([string]$Notify.Secret)
                    $toSign = $ts.ToString() + "`n" + [string]$Notify.Secret
                    $raw = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($toSign))
                    $sign = [System.Uri]::EscapeDataString([Convert]::ToBase64String($raw))
                    $url = $url + '&timestamp=' + $ts + '&sign=' + $sign
                }
                $json = @{ msgtype = 'text'; text = @{ content = $Body } } | ConvertTo-Json -Depth 5
                $resp = Send-JsonPost -Url $url -Json $json
                if ($resp.errcode -eq 0) { $result.Ok = $true; $result.Message = '钉钉发送成功' }
                else { $result.Message = ('钉钉返回：' + $resp.errcode + ' ' + $resp.errmsg) }
            }
            'wecom' {
                $json = @{ msgtype = 'text'; text = @{ content = $Body } } | ConvertTo-Json -Depth 5
                $resp = Send-JsonPost -Url ([string]$Notify.Webhook) -Json $json
                if ($resp.errcode -eq 0) { $result.Ok = $true; $result.Message = '企业微信发送成功' }
                else { $result.Message = ('企业微信返回：' + $resp.errcode + ' ' + $resp.errmsg) }
            }
            'feishu' {
                $json = @{ msg_type = 'text'; content = @{ text = $Body } } | ConvertTo-Json -Depth 5
                $resp = Send-JsonPost -Url ([string]$Notify.Webhook) -Json $json
                if ($resp.code -eq 0 -or $resp.StatusCode -eq 0) { $result.Ok = $true; $result.Message = '飞书发送成功' }
                else { $result.Message = ('飞书返回：' + $resp.code + ' ' + $resp.msg) }
            }
            'qqmail' {
                $client = New-Object System.Net.Mail.SmtpClient('smtp.qq.com', 587)
                $client.EnableSsl = $true
                $client.Timeout = 20000
                $client.Credentials = New-Object System.Net.NetworkCredential([string]$Notify.MailFrom, [string]$Notify.MailAuthCode)
                $mail = New-Object System.Net.Mail.MailMessage
                $mail.From = New-Object System.Net.Mail.MailAddress([string]$Notify.MailFrom)
                foreach ($to in ([string]$Notify.MailTo).Split(',')) {
                    $addr = $to.Trim()
                    if ($addr) { [void]$mail.To.Add($addr) }
                }
                $mail.Subject = $Subject
                $mail.Body = $Body
                $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
                $mail.BodyEncoding = [System.Text.Encoding]::UTF8
                $client.Send($mail)
                $mail.Dispose()
                $client.Dispose()
                $result.Ok = $true
                $result.Message = '邮件发送成功'
            }
            default { $result.Message = ('不认识的通知方式：' + $channel) }
        }
    } catch {
        $result.Message = ('发送失败：' + $_.Exception.Message)
    }

    return $result
}
