# Nash Tunnel

اسکریپت و پنل مدیریت تونل معکوس: GRE، FRP، Backhaul (Xray)، بههمراه واچداگ، بنچمارک و فیلاور.

جایگزین متنباز پنلهای تجاری این حوزه است؛ بدون لایسنس، بدون قفل و بدون محدودیت تعداد سرور.

<p align="center">
  <img src="docs/panel.png" alt="Nash Tunnel panel" width="100%">
</p>


```
┌──────────────┐        GRE (L3)        ┌──────────────┐
│  IRAN server │◄══════════════════════►│ FOREIGN node │
│  (public IP) │                        │  (public IP) │
│              │◄──── FRP (reverse) ────│              │
│              │◄──── Xray REALITY ─────│              │
└──────┬───────┘                        └──────────────┘
       │
   :8090 panel  ──►  dashboard / watchdog / logs / benchmark
```

## نصب سریع

```bash
curl -fsSL https://raw.githubusercontent.com/frank0live/nash-tunnel/main/install.sh | bash
```

این نصب یکخطی را می‌توان داخل اسکریپت دیگر یا بدون ترمینال هم اجرا کرد؛ منو
متوقف نمی‌شود و بهجای آن، دستورهای غیرتعاملی نمایش داده می‌شوند.

یا دستی:

```bash
git clone https://github.com/frank0live/nash-tunnel.git
cd nash-tunnel
bash nash.sh          # منوی تعاملی
```

## دستور‌ها

| دستور | کار |
|---|---|
| `bash nash.sh status` | گزارش کامل سلامت (CPU/RAM/دیسک/سرویس‌ها/تونل) |
| `bash nash.sh install-iran` | نصب روی سرور ایران (GRE server + frps + پنل) |
| `bash nash.sh install-foreign` | نصب روی سرور خارج (GRE client + frpc + پنل) |
| `bash nash.sh backhaul` | ساخت سمت سرور Backhaul (Xray REALITY) |
| `bash nash.sh backhaul-client ...` | ساخت سمت کلاینت Backhaul |
| `bash nash.sh watchdog` | نصب/رفرش واچداگ (هر ۶۰ ثانیه) |
| `bash nash.sh benchmark` | تست پینگ/تاخیر همهٔ نود‌ها و رتبهبندی |
| `bash nash.sh panel` | ریستارت پنل |
| `bash nash.sh uninstall` | حذف کامل |

## پنل وب

- آدرس: `http://SERVER_IP:8090`
- رمز در پایان نصب چاپ می‌شود (تصادفی، ۱۴ کاراکتر)
- تغییر رمز: `bash nash.sh` و بعد گزینه ۹
- چه چیزهایی نشان می‌دهد: وضعیت زندهٔ CPU، RAM، دیسک و آپتایم، وضعیت سرویسها،
  ریستارت تککلیکی، تست زندهٔ نود‌ها و لاگ‌ها. رابط فارسی و راستبهچپ است.

## Watchdog

سرویس systemd با تایمر ۶۰ ثانیهای که سرویسهای `nash-panel`، `nash-frps`،
`nash-frpc` و `nash-backhaul` را بررسی می‌کند و لینک `nash-gre` را نیز زیر نظر دارد.
هر سرویسی که افتاده باشد ریستارت می‌شود و نتیجه به تلگرام ارسال می‌شود. توکن و
چتآیدی را در `/etc/nash/config.json` قرار دهید.

## ساختار فایل‌ها

```
nash.sh                 اسکریپت اصلی (نصب/مدیریت/منو)
install.sh              نصب یکخطی
panel/panel.py          بکاند پنل (پایتون stdlib، بدون وابستگی)
web/index.html          فرانت پنل (تکفایل، RTL)
systemd/                یونیتهای نمونه
/etc/nash/config.json   تنظیمات (پورت، نودها، تلگرام)
/etc/nash/panel.json    هش رمز و سشن‌ها
/etc/nash/frps.toml     تنظیمات FRP server
/etc/nash/frpc.toml     تنظیمات FRP client
/etc/nash/backhaul/     کانفیگهای Xray
```

## امنیت

- رمز پنل با PBKDF2-SHA256 و ۱۲۰٬۰۰۰ دور هش می‌شود
- سشن با کوکی HttpOnly و SameSite=Strict، عمر ۱۲ ساعت
- توکن FRP و کلید GRE تصادفی ساخته می‌شوند
- فایلهای حساس مجوز `600` دارند

پیشنهاد می‌شود پنل را پشت Nginx با TLS قرار دهید، یا دسترسی را به IP خودتان محدود کنید:

```bash
ufw allow from YOUR_IP to any port 8090
```

## عیبیابی

### منو پشت سر هم `! invalid choice` چاپ می‌کند

یعنی stdin به ترمینال متصل نیست؛ مثلاً وقتی با `curl ... | bash` یا از داخل یک
ابزار اجرا می‌شود. از نسخه ۱.۰.۱، خود اسکریپت به `/dev/tty` متصل می‌شود. اگر
ترمینالی در کار نبود، از دستورهای غیرتعاملی استفاده کنید:

```bash
bash nash.sh status
bash nash.sh install-iran
bash nash.sh install-foreign
```

### `Job for nash-gre.service failed ... invalid value for "key"`

کلید تونل باید عدد باشد. نسخههای قدیمی آن را با حرف می‌ساختند، پس سرویس بلافاصله
می‌مرد. کانفیگ را دوباره بساز:

```bash
rm -f /etc/nash/gre.key
bash nash.sh install-iran      # کلید عددی جدید چاپ می‌شود
```

سپس در سرور خارج همان کلید را وارد کنید. مقدار آن در دو سرور باید یکسان باشد،
وگرنه تونل بالا می‌آید ولی ترافیکی عبور نمی‌کند:

```bash
cat /etc/nash/gre.key                 # باید در دو سرور یکی باشد
ip -d link show nash-gre | grep ikey  # کلید فعال اینترفیس
```

### `Job for nash-backhaul.service failed` یا `invalid "shortIds[0]"`

shortId باید هگز باشد (`0-9a-f`). کانفیگ را از گزینه ۴ منو دوباره بساز.

### پینگ TCP برمی‌گردد ولی دیتا رد نمی‌شود (Real Delay روی `-1ms`)

اگر ترافیک را در سرور خارج به سرویسی روی لوکالهاست همان سرور فوروارد می‌کنید (پنل
3x-ui، sshd، nginx) و آن سرویس هیچ درخواستی ثبت نمی‌کند، مشکل از کانفیگ شما نیست.

از Xray نسخه v26.4.17 به بعد (PR [#5947](https://github.com/XTLS/Xray-core/pull/5947))
خروجی `freedom` بهطور پیشفرض مقصدهای private و reserved، از جمله `127.0.0.1` را
blackhole می‌کند. این تدبیر برای جلوگیری از SSRF گذاشته شده. نسخههای ۱.۰.۱ و
قدیمیتر این اسکریپت کانفیگ سرور خارج را با یک `freedom` خالی می‌ساختند:

```json
"outbounds": [{ "protocol": "freedom" }]
```

یعنی هر فورواردی به سرویس لوکال سرور خارج بیصدا می‌مرد. علامتش هم گمراهکننده
است: پینگ TCP برمیگردد و `curl telnet://` وصل می‌شود، ولی Real Delay تایماوت
می‌دهد و پنل هیچ درخواستی ثبت نمی‌کند. با `"loglevel": "warning"` هم چیزی در لاگ
دیده نمی‌شود؛ فقط با `info` معلوم می‌شود:

```
proxy/freedom: blocked target: tcp:127.0.0.1:2053, blackholing connection for 47s
```

مقصد `dokodemo-door` در سمت ایران، در انتهای تونل و روی سرور خارج تفسیر می‌شود؛
بنابراین مقدار `127.0.0.1` درست است و به لوکالهاست سرور خارج اشاره می‌کند. نیازی
به نوشتن IP عمومی سرور خارج نیست.

از نسخه ۱.۰.۲ این بلاک برداشته شده و `outbounds` سرور خارج چنین شکلی دارد:

```json
"outbounds": [{
  "protocol": "freedom",
  "settings": {
    "finalRules": [
      {"action": "allow", "network": "tcp", "ip": ["127.0.0.1/32", "::1/128"]}
    ]
  }
}]
```

فقط لوکالهاست باز شده و بقیهٔ آدرسهای private مثل قبل بسته می‌مانند. اگر با
نسخهای قدیمیتر کانفیگ ساختهاید، در سرور خارج آن را دوباره بسازید:

```bash
bash nash.sh backhaul
systemctl restart nash-backhaul
```

یا این بلاک را به `settings` خروجی `freedom` در
`/etc/nash/backhaul/server.json` اضافه کنید و سرویس را ریستارت کنید.

برای اطمینان از اینکه مشکل همین است، لاگ را موقتاً باز کنید:

```bash
sed -i 's/"loglevel": "warning"/"loglevel": "info"/' /etc/nash/backhaul/server.json
systemctl restart nash-backhaul && journalctl -u nash-backhaul -f
```

## Support

- Telegram: [@master_supports](https://t.me/master_supports)

## لایسنس
