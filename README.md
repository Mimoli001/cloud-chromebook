# Cloud "Chromebook" on GitHub Actions

یک **کروم‌بوک ابری**: دسکتاپ کامل لینوکس همراه با Google Chrome، کِروم‌بوک‌مانند (پنل پایین + آیکن برنامه‌ها)،
که با اجرای یک ورک‌فلو در **GitHub Actions** بالا می‌آید و تصویر زندهٔ آن با
`x11vnc + noVNC` از طریق تونل سریع **trycloudflare.com** به مرورگر خودتان می‌رسد.

CPU، رم، دیسک و پهنای‌باند همه از خودِ رانر GitHub Actions است؛ هیچ سرور یا نصب محلی لازم نیست.
(نسخهٔ وب پروژهٔ ترمینال [bug-free-giggle](https://github.com/Mimoli001/bug-free-giggle) — بدون بخش‌های امنیت و ذخیره‌سازی.)

> ⚠️ **این ریپو عمومی است و ورک‌فلو رمز ندارد:** هر کسی که تب Actions را ببیند، همان لینک `trycloudflare` را می‌بیند
> و تا پایان سشن می‌تواند وارد دسکتاپ شود. سشن را کوتاه نگه دار (`session_minutes`)، لینک را جای عمومی پست نکن،
> و کارت که تمام شد اجرا را **Cancel** کن. برای استفادهٔ جدی امنیت را اضافه کن (پایین توضیح داده شده).

```
                    رانر GitHub Actions (ubuntu-latest)                     مرورگر شما
┌───────────────────────────────────────────────────────────────┐   ┌────────────────────┐
│  Xvfb (:99) ─ openbox ─ tint2 shelf ─ Google Chrome           │   │                    │
│        │                                                      │   │   https://<rand>.  │
│        ├── x11vnc      127.0.0.1:5900  (RFB، بدون رمز)        │   │   trycloudflare.   │
│        └── websockify  127.0.0.1:6080  (noVNC: HTTP + WS)     │   │   com              │
│                 │                                             │   └─────────▲──────────┘
│                 └── cloudflared quick tunnel ──────────────────────────────┘
└───────────────────────────────────────────────────────────────┘
```

## راه‌اندازی (۳ مرحله)

1. این پوشه همین حالا در ریپوی [Mimoli001/cloud-chromebook](https://github.com/Mimoli001/cloud-chromebook) پابلیک است
   (اگر خصوصی می‌خواهی: `gh repo edit --visibility private --accept-visibility-change-consequences`).
2. تب **Actions** → ورک‌فلوی **chromebook** → دکمهٔ **Run workflow**.
3. صبر کنید تا مرحلهٔ *Boot* تمام شود (~۲ تا ۴ دقیقه؛ بار اول بیشتر) و بعد یکی از این‌ها را باز کنید:

   * آدرس `https://<random>.trycloudflare.com` که در خلاصهٔ اجرا (Job Summary) و در لاگ با یک `::notice` نشان داده می‌شود،
   * اگر Secrets تلگرام را ست کرده باشید، همان لینک به تلگرام هم می‌آید.

   در صفحهٔ اول دکمهٔ **اتصال به دسکتاپ** را بزنید؛ Chrome در حالت تمام‌پنجره با یک شلف پایین‌ مثل ChromeOS باز می‌شود.

## داخل دسکتاپ چه خبر است؟

| | |
|---|---|
| **Google Chrome** | با فلگ‌های مناسب رانر (`--no-sandbox --disable-gpu`)، صفحهٔ اول یک «تب تازه»ٔ کِروم‌بوکی با آیکن سایت‌های پرکاربرد و جست‌وجوگر گوگل |
| **شلف پایین (tint2)** | آیکن Chrome، ترمینال (`xterm`)، فایل‌منیجر (`pcmanfm`)، ساعت |
| **ترمینال** | `sudo apt-get install ...`، `pip`، `npm`، `git` … همه در همان سشن کار می‌کنند (موقتی) |
| **فونت‌ها** | Vazirmatn + Noto (فارسی/عربی درست رندر می‌شود) |
| **کلیپ‌بورد** | بین مرورگر شما و دسکتاپ همگام است (از نوار کناری noVNC یا `Ctrl+Alt+Shift+V`) |

## ورودی‌های ورک‌فلو

| ورودی | پیش‌فرض | توضیح |
|---|---|---|
| `resolution` | `1600x900` | اندازهٔ صفحه. کوچک‌تر = روان‌تر (`1366x768`، `1280x720`) |
| `start_url` | خالی | صفحه‌ای که Chrome اول باز می‌کند (خالی = صفحهٔ شروع داخلی) |
| `ui_language` | `fa` | زبان رابط کاربری Chrome (`fa` = فارسی، `en-US` = انگلیسی) |
| `session_minutes` | `300` | مدت‌زمان سشن به دقیقه (حداکثر ۳۵۰، چون سقف هر Job در گیت‌هاب ۶ ساعت است) |
| `chain` | `false` | با تمام شدن زمان، خودکار یک اجرای تازه (لینک تازه) استارت شود |

### تنظیمات اختیاری مخزن (Secrets / Variables)

| نوع | نام | کار |
|---|---|---|
| Secret | `TG_BOT_TOKEN`, `TG_CHAT_ID` | لینک آماده‌شدن سشن (و لینک جدید بعد از ری‌استارت تونل) به تلگرام می‌آید |
| Secret | `CF_TUNNEL_TOKEN` | اگر تونل نام‌دار خودتان را دارید، به‌جای trycloudflare از آن استفاده می‌شود |
| Variable | `CF_HOSTNAME` | دامنهٔ ثابت آن تونل نام‌دار (مثلاً `cloud.example.com`) |

> ⚠️ توصیه: با `CF_TUNNEL_TOKEN` + **Cloudflare Access** می‌توانید رمز/احراز هویت جلوی دسکتاپ بگذارید.
> پروژهٔ قبلی همین را داشت؛ این‌جا برای سادگی پیاده نشده و طبق درخواست شما بخش امنیت/ذخیره‌سازی حذف شده است.

## محدودیت‌ها (بخوانید!)

* **سقف ۶ ساعت** برای هر Job. با `chain: true` می‌شود زنجیرهٔ پشت‌سرهم ساخت، ولی هر اجرا **لینک و دسکتاپ تازه** دارد
  (چون بخش ذخیره‌سازی/اسنپ‌شات در این نسخه نیست؛ هرچه نصب یا ذخیره کنید با پایان سشن می‌رود).
* منابع رانر: ۲ هستهٔ CPU، ۷ گیگ رم، ~۱۴ گیگ دیسک. کارهای سبک (وب‌گردی، چت، کدنویسی، ایمیل) خوب است؛
  ویدیوی سنگین و بازی نه (GPU ندارد، رندر نرم‌افزاری است).
* تونل quick محبوب است ولی تضمین SLA ندارد؛ اگر لینک باز نشد یک‌بار دیگر Run workflow بزنید.
* تأخیر تصویر معمولاً ۸۰–۳۰۰ms است؛ `quality`/`compression` در `chromebook.sh` (`NOVNC_QUALITY`, `NOVNC_COMPRESSION`) قابل تنظیم است.
* لینک quick tunnel **رمز ندارد** و این ریپو پابلیک است: هر کسی که تب Actions را باز کند لینک را می‌بیند.
  سشن‌های کوتاه، Cancel کردن بعد از کار، و لینک نگذار جای عمومی. اگر برای کار جدی می‌خواهی، از `CF_TUNNEL_TOKEN` +
  Cloudflare Access استفاده کن، یا ریپو را خصوصی کن.

## عیب‌یابی

| نشانه | کار |
|---|---|
| لینک در لاگ نیست | مرحلهٔ *Boot* را ببینید و `$LOGS/cloudflared.log` را وقتی سشن بالاست با ترمینال خودِ دسکتاپ بخوانید |
| «اتصال به دسکتاپ» صفحهٔ سیاه می‌دهد | چند ثانیه صبر کنید (noVNC هر ۲ ثانیه retry می‌کند) یا `vnc_lite.html` را امتحان کنید |
| تصویر یخ می‌زند | در نوار کناری noVNC → `Disconnect` و دوباره وصل شوید؛ watchdog در ورک‌فلو سرویس‌های مرده را ری‌استارت می‌کند |
| Chrome بالا نمی‌آید | در ترمینال: `pgrep -a chrome`، `cat /tmp/chromebook/logs/chrome.log` |
| می‌خواهم چند ساعت بیشتر | `session_minutes` و `chain: true` |

لاگ همهٔ سرویس‌ها در `/tmp/chromebook/logs/` رانر است (`xvfb`, `openbox`, `tint2`, `x11vnc`, `websockify`, `cloudflared`, `chrome`).

## ساختار فایل‌ها

```
.github/workflows/chromebook.yml        ورک‌فلو: نصب، بوت، سشن watchdog، زنجیره‌سازی
.github/chromebook/chromebook.sh        اسکریپت اصلی: install | boot | hold | url | status
.github/chromebook/assets/wallpaper.py  ساخت والپیپر (فقط کتابخانهٔ استاندارد پایتون)
.github/chromebook/assets/tint2rc       شلف پایین (آیکن‌ها/تسک‌بار/ساعت)
.github/chromebook/assets/openbox/rc.xml تنظیم پنجره‌ها (Chrome بدون حاشیه و تمام‌صفحه)
.github/chromebook/assets/web/index.html صفحهٔ اول لینک عمومی (لانچر اتصال)
.github/chromebook/assets/web/home.html  صفحهٔ شروع Chrome داخل دسکتاپ
```

## اجرای دستیِ اسکریپت روی هر لینوکس (برای تست)

```bash
export RESOLUTION=1366x768 SESSION_SECONDS=3600
bash .github/chromebook/chromebook.sh install
bash .github/chromebook/chromebook.sh boot
bash .github/chromebook/chromebook.sh status   # در ترمینال دیگر
bash .github/chromebook/chromebook.sh hold     # تا زمان‌سقف بیدار نگه می‌دارد
```
