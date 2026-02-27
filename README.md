<p align="center">
  <img src="https://raw.githubusercontent.com/ItzGlace/bifrost-gate/refs/heads/main/logo.png" alt="Bifrost Gate Logo" width="180" />
</p>

# Bifrost Gate

---

## فارسی

### نصب سریع

```bash
bash <(curl -Ls https://raw.githubusercontent.com/ItzGlace/bifrost-gate/refs/heads/main/install.sh)
```

در حین نصب از شما این موارد پرسیده می‌شود:
- نام کاربری پنل
- رمز پنل
- پورت پنل/API (پیش‌فرض: `11001`)

---

### نصب در زمان محدودیت دسترسی به GitHub

اگر سرور شما به GitHub دسترسی ندارد، از `offline.sh` استفاده کنید:

```bash
sudo bash offline.sh
```

این اسکریپت می‌تواند با فایل‌های همین پوشه (local assets) نصب را کامل کند.  
در صورت نیاز، فایل‌های زیر را کنار اسکریپت نگه دارید:
- `bifrost-gate-linux-amd64.zip`
- `bifrost-gate-linux-arm64.zip`
- `bifrost-gate-linux-armv7.zip`
- `bifrost-manager.sh`

نکته: اگر فایل باینری خام (`bifrost-gate-linux-amd64` و ...) موجود باشد، همان را مستقیم استفاده می‌کند.

---

### مدیریت سرویس

- وضعیت سرویس:

```bash
bifrost status
```

- شروع/توقف/ری‌استارت:

```bash
bifrost start
bifrost stop
bifrost restart
```

- لاگ زنده:

```bash
bifrost logs -f
```

- آدرس پنل:

```text
http://SERVER_IP:11001/login
```

---

### آموزش اتصال x-ui با WebSocket

برای تونل x-ui باید یک Inbound جدید از نوع WebSocket در x-ui بسازید و با مقادیر پنل Bifrost یکسان کنید.

#### 1) تنظیم Listener در پنل Bifrost

در بخش Listeners یک Listener بسازید و مقادیر را ثبت کنید:
- `listen_port`
- `required_host` (یا در صورت نیاز `rewrite_host_to`)
- `path_prefix`
- `target_host`
- `target_port`

#### 2) ساخت Inbound در x-ui

در x-ui یک Inbound جدید بسازید و Network/Transport را روی **WebSocket** بگذارید.

تطبیق فیلدها:
- `WS Path` در x-ui = `path_prefix` در Bifrost
- `WS Host` در x-ui = `required_host` در Bifrost (یا `rewrite_host_to` اگر استفاده می‌کنید)
- `Inbound Port` در x-ui = `target_port` در Bifrost
- اگر x-ui روی همان سرور است، `target_host` را `127.0.0.1` بگذارید

#### 3) آدرس اتصال کلاینت

کلاینت باید به پورت Listener بیفراست وصل شود:
- `SERVER_IP:listen_port`
- با همان `Host` و `Path` تعریف‌شده

---

## English

### Quick Setup

direct one-line install:

```bash
curl -fsSL https://raw.githubusercontent.com/ItzGlace/bifrost-gate/refs/heads/main/install.sh | sudo bash
```

You will be prompted for:
- Panel username
- Panel password
- Panel/API port (default: `11001`)

---

### Setup when GitHub access is restricted

If your server cannot access GitHub, use `offline.sh`:

```bash
sudo bash offline.sh
```

`offline.sh` can install directly from local files in this folder.  
Keep these files next to the script when needed:
- `bifrost-gate-linux-amd64.zip`
- `bifrost-gate-linux-arm64.zip`
- `bifrost-gate-linux-armv7.zip`
- `bifrost-manager.sh`

Note: if raw binaries (`bifrost-gate-linux-amd64`, etc.) are present, they are used directly.

---

### Service Management

- Service status:

```bash
bifrost status
```

- Start/stop/restart:

```bash
bifrost start
bifrost stop
bifrost restart
```

- Follow logs:

```bash
bifrost logs -f
```

- Panel URL:

```text
http://SERVER_IP:11001/login
```

---

### x-ui WebSocket Tunneling Guide

For x-ui tunneling, create a new **WebSocket inbound** in x-ui and match it with Bifrost panel values.

#### 1) Create Listener in Bifrost panel

In the Listeners section, create a listener and note:
- `listen_port`
- `required_host` (or `rewrite_host_to` if used)
- `path_prefix`
- `target_host`
- `target_port`

#### 2) Create WebSocket inbound in x-ui

In x-ui, create a new inbound and set Network/Transport to **WebSocket**.

Field mapping:
- x-ui `WS Path` = Bifrost `path_prefix`
- x-ui `WS Host` = Bifrost `required_host` (or `rewrite_host_to` if you use rewrite)
- x-ui `Inbound Port` = Bifrost `target_port`
- If x-ui runs on the same server, set `target_host` to `127.0.0.1`

#### 3) Client connection target

Clients must connect to the Bifrost listener:
- `SERVER_IP:listen_port`
- using the same `Host` and `Path`
