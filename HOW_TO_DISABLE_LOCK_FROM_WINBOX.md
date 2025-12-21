# راهنمای غیرفعال کردن قفل اتصال جدید از WinBox

اگر قفل اتصال جدید فعال شده و شما خودتان هم مسدود شده‌اید، می‌توانید از WinBox آن را غیرفعال کنید.

## روش سریع: استفاده از Terminal (توصیه می‌شود)

اگر می‌توانید به Terminal دسترسی داشته باشید، این روش سریع‌ترین است:

1. در WinBox، به **`New Terminal`** بروید
2. دستورات زیر را به ترتیب اجرا کنید:

**برای حذف marker:**
```
system identity set name="MikroTik"
```
(به جای `MikroTik`، نام اصلی روتر خود را وارد کنید)

**برای حذف rule های firewall:**
```
ip firewall raw remove [find comment~"Auto-banned"]
ip firewall raw remove [find comment~"Lock New Connections"]
```

**برای حذف wireless access list:**
```
interface wireless access-list remove [find comment="Lock New Connections - Allowed Device"]
```

**نکته:** اگر از WinBox Terminal استفاده می‌کنید و دستورات با `/` کار نمی‌کند، از دستورات بدون `/` استفاده کنید.

---

## بررسی وضعیت قفل (چک کردن که آیا قفل غیرفعال شده است)

بعد از اجرای دستورات بالا، می‌توانید با دستورات زیر بررسی کنید که آیا قفل به درستی غیرفعال شده است:

### 1. بررسی System Identity (Marker)

```
system identity print
```

**نتیجه صحیح:** نباید `[LOCKED_NEW_CONN]` در نام روتر باشد.

**مثال خروجی صحیح:**
```
name: MikroTik
```

**مثال خروجی اشتباه (هنوز قفل فعال است):**
```
name: MikroTik [LOCKED_NEW_CONN]
```

### 2. بررسی Firewall Raw Rules

```
ip firewall raw print where comment~"Auto-banned"
ip firewall raw print where comment~"Lock New Connections"
```

**نتیجه صحیح:** نباید rule ای با comment مربوط به قفل وجود داشته باشد.

**اگر rule پیدا شد:** باید آن را حذف کنید:
```
ip firewall raw remove [find comment~"Auto-banned"]
ip firewall raw remove [find comment~"Lock New Connections"]
```

### 3. بررسی Wireless Access List

```
interface wireless access-list print where comment="Lock New Connections - Allowed Device"
```

**نتیجه صحیح:** نباید rule ای با comment `Lock New Connections - Allowed Device` وجود داشته باشد.

**اگر rule پیدا شد:** باید آن را حذف کنید:
```
interface wireless access-list remove [find comment="Lock New Connections - Allowed Device"]
```

### 4. بررسی کامل (یک دستور برای همه)

برای بررسی سریع همه موارد:

```
:put "=== بررسی System Identity ==="
system identity print
:put ""
:put "=== بررسی Firewall Raw Rules ==="
ip firewall raw print where comment~"Auto-banned" or comment~"Lock New Connections"
:put ""
:put "=== بررسی Wireless Access List ==="
interface wireless access-list print where comment="Lock New Connections - Allowed Device"
```

**نتیجه صحیح:** 
- System Identity نباید `[LOCKED_NEW_CONN]` داشته باشد
- Firewall Raw Rules نباید rule ای با comment مربوط به قفل داشته باشد
- Wireless Access List نباید rule ای با comment `Lock New Connections - Allowed Device` داشته باشد

---

## روش 1: حذف Marker از System Identity (ساده‌ترین روش)

1. در WinBox، به **`System`** بروید
2. روی **`Identity`** کلیک کنید
3. در فیلد **`Name`**، متن `[LOCKED_NEW_CONN]` را پیدا کنید
4. این متن را حذف کنید (فقط نام روتر را نگه دارید)
5. روی **`OK`** کلیک کنید

این کار marker قفل را حذف می‌کند و قفل غیرفعال می‌شود.

## روش 2: حذف Wireless Access List Rules

1. در WinBox، به **`Wireless`** بروید
2. روی **`Access List`** کلیک کنید
3. تمام rule هایی که comment آن‌ها **`Lock New Connections - Allowed Device`** است را پیدا کنید
4. rule های مربوط به قفل را انتخاب کرده و با دکمه **`X`** (Remove) حذف کنید

**نکته:** این کار فقط rule های wireless را حذف می‌کند. برای اطمینان کامل، روش 1 را هم انجام دهید.

## روش 3: حذف از طریق Terminal (WinBox Terminal)

1. در WinBox، به **`New Terminal`** بروید
2. دستور زیر را اجرا کنید (بدون `/` در ابتدا):

```
system identity set name="نام_روتر_شما"
```

(به جای `نام_روتر_شما`، نام اصلی روتر خود را بدون `[LOCKED_NEW_CONN]` وارد کنید)

**مثال:**
```
system identity set name="MikroTik"
```

3. برای حذف wireless access list rules:

```
interface wireless access-list remove [find comment="Lock New Connections - Allowed Device"]
```

**یا اگر از WinBox Terminal استفاده می‌کنید (با `/`):**

```
/system/identity/set name="MikroTik"
/interface/wireless/access-list/remove [find comment="Lock New Connections - Allowed Device"]
```

## روش 4: استفاده از اپلیکیشن (اگر می‌توانید به اپلیکیشن دسترسی داشته باشید)

1. اپلیکیشن را باز کنید
2. به صفحه اصلی بروید
3. دکمه **"قفل اتصال جدید"** را پیدا کنید
4. اگر قفل فعال است (نارنجی رنگ)، روی آن کلیک کنید
5. در dialog تأیید، **"رفع قفل"** را انتخاب کنید

## روش 5: حذف Firewall Raw Rules (اگر IP شما مسدود شده)

اگر نمی‌توانید با IP به WinBox متصل شوید (فقط با MAC می‌توانید)، احتمالاً rule های firewall IP شما را مسدود کرده‌اند:

1. در WinBox، به **`IP`** بروید
2. روی **`Firewall`** کلیک کنید
3. به تب **`Raw`** بروید
4. rule هایی که comment آن‌ها شامل **`Auto-banned: New connection while locked`** یا **`Lock New Connections`** است را پیدا کنید
5. rule هایی که IP شما را مسدود می‌کنند را انتخاب کرده و با دکمه **`X`** (Remove) حذف کنید

**یا از Terminal (بدون `/` در ابتدا):**

```
ip firewall raw remove [find comment~"Auto-banned: New connection while locked"]
ip firewall raw remove [find comment~"Lock New Connections"]
```

**یا اگر از WinBox Terminal استفاده می‌کنید (با `/`):**

```
/ip/firewall/raw/remove [find comment~"Auto-banned: New connection while locked"]
/ip/firewall/raw/remove [find comment~"Lock New Connections"]
```

**نکته:** اگر خطای syntax دریافت کردید، از دستورات بدون `/` استفاده کنید یا از GUI استفاده کنید.

## نکات مهم

- بعد از غیرفعال کردن قفل، ممکن است نیاز به refresh کردن اتصال داشته باشید
- اگر هنوز مسدود هستید، بررسی کنید که آیا rule های firewall شما را block می‌کنند یا نه
- برای بررسی rule های firewall، به **`IP` -> `Firewall` -> `Raw`** بروید و rule هایی با comment **`Auto-banned: New connection while locked`** را بررسی کنید
- **اگر نمی‌توانید با IP به WinBox متصل شوید**، از MAC address استفاده کنید یا rule های firewall را از طریق Terminal حذف کنید

## مشکل: دستگاه‌هایی که در زمان فعال شدن قفل متصل بودند، حالا نمی‌توانند متصل شوند

اگر بعد از غیرفعال کردن قفل، دستگاه‌هایی که در زمان فعال شدن قفل متصل بودند نمی‌توانند متصل شوند، احتمالاً rule های firewall یا DHCP block آن‌ها را مسدود کرده‌اند.

### راه حل: حذف rule های firewall و رفع block از DHCP leases

#### 1. بررسی و حذف rule های firewall که IP یا MAC دستگاه‌های مجاز را مسدود می‌کنند

**بررسی rule های firewall بر اساس IP:**
```
ip firewall raw print
```

**بررسی rule های firewall بر اساس MAC:**
```
ip firewall raw print where src-mac-address!=""
```

**حذف همه rule های firewall که مربوط به قفل هستند (احتیاط: این همه rule های مربوط به قفل را حذف می‌کند):**
```
ip firewall raw remove [find comment~"Auto-banned"]
ip firewall raw remove [find comment~"Banned"]
```

**یا حذف rule های خاص بر اساس IP (به جای IP_DEVICE، IP دستگاه را وارد کنید):**
```
ip firewall raw remove [find src-address="IP_DEVICE"]
```

**یا حذف rule های خاص بر اساس MAC (به جای MAC_DEVICE، MAC دستگاه را وارد کنید):**
```
ip firewall raw remove [find src-mac-address="MAC_DEVICE"]
```

#### 2. بررسی و رفع block از DHCP leases

**بررسی DHCP leases که block شده‌اند:**
```
ip dhcp-server lease print where block-access=yes
```

**رفع block از همه DHCP leases:**
```
ip dhcp-server lease set [find block-access=yes] block-access=no
```

**یا رفع block از DHCP lease خاص (به جای MAC_DEVICE، MAC دستگاه را وارد کنید):**
```
ip dhcp-server lease set [find mac-address="MAC_DEVICE"] block-access=no
```

#### 3. بررسی Wireless Access List

**بررسی rule های wireless که deny یا reject هستند:**
```
interface wireless access-list print where action="deny" or action="reject"
```

**حذف rule های wireless که deny یا reject هستند (احتیاط: این همه rule های deny/reject را حذف می‌کند):**
```
interface wireless access-list remove [find action="deny"]
interface wireless access-list remove [find action="reject"]
```

#### 4. راه حل کامل (یک دستور برای همه)

برای رفع کامل مسدودیت از همه دستگاه‌های مجاز:

```
# حذف همه rule های firewall مربوط به قفل
ip firewall raw remove [find comment~"Auto-banned"]
ip firewall raw remove [find comment~"Banned"]

# رفع block از همه DHCP leases
ip dhcp-server lease set [find block-access=yes] block-access=no

# حذف rule های wireless که deny یا reject هستند
interface wireless access-list remove [find action="deny" and comment~"Lock"]
interface wireless access-list remove [find action="reject" and comment~"Lock"]
```

#### 5. بررسی نهایی

بعد از اجرای دستورات بالا، بررسی کنید:

```
# بررسی rule های firewall باقی‌مانده
ip firewall raw print

# بررسی DHCP leases که هنوز block هستند
ip dhcp-server lease print where block-access=yes

# بررسی rule های wireless باقی‌مانده
interface wireless access-list print
```

---

## جلوگیری از مسدود شدن در آینده

اپلیکیشن به صورت خودکار MAC دستگاه شما را در زمان فعال شدن قفل به لیست مجاز اضافه می‌کند. اما اگر بعد از فعال شدن قفل متصل شده‌اید، ممکن است مسدود شوید.

برای جلوگیری از این مشکل:
- قبل از فعال کردن قفل، مطمئن شوید که به شبکه متصل هستید
- یا بعد از فعال شدن قفل، MAC خود را به صورت دستی به wireless access list اضافه کنید

