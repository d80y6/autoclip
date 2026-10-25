# نشر AutoClip: الواجهة على Cloudflare والـ Backend على Railway

هذا الدليل يشرح نشر AutoClip على الإنترنت بالمعمارية التالية:

```
                        المتصفح
                           │
          ┌────────────────┴─────────────────┐
          │                                  │
   HTTPS (صفحات ثابتة)              HTTPS /api/v1 (مع CORS)
          │                                  │
┌─────────▼──────────┐            ┌──────────▼────────────────────┐
│ Cloudflare Workers │            │ Railway: حاوية واحدة           │
│  frontend/dist     │            │  FastAPI + Celery worker       │
│  (React + Vite)    │            │  ffmpeg + yt-dlp + SQLite      │
└────────────────────┘            │  Volume: /app/data             │
                                  └──────────┬────────────────────┘
                                             │ REDIS_URL
                                  ┌──────────▼──────────┐
                                  │  Railway: Redis     │
                                  └─────────────────────┘
```

لماذا هذا التقسيم؟

- **Cloudflare Workers** ممتازة لملفات ثابتة (سرعة، تكلفة صفر ضمن الحد المجاني)، لكنها لا تستطيع تشغيل
  FastAPI + ffmpeg + yt-dlp ولا مهام طويلة (معالجة فيديو تستمر دقائق). Workers ليست بيئة Python.
- **Railway** تشغّل حاوية Docker كاملة: ffmpeg، yt-dlp، SQLite، Redis، Celery — وهذا ما يحتاجه المشروع.
- الواجهة تنادي الـ API مباشرة عبر HTTPS (CORS)، وليس عبر Worker وسيط، حتى لا تتعارض عمليات رفع
  الفيديوهات الكبيرة مع حدود حجم الطلب في Workers (100 ميغابايت في الخطة المجانية).

> ملاحظة مهمة: Railway لم تعد تقرأ ملف `railway.json` (Config-as-code) للخدمات الجديدة — أُوقف في
> 2026-12-01. لذلك كل إعدادات النشر هنا إمّا **متغيرات بيئة** أو **إعدادات في لوحة Railway**، ولا يوجد
> ملف config-as-code في المستودع.

---

## 0. ما تم تجهيزه في المستودع

| الملف | الغرض |
| --- | --- |
| `deploy/railway/Dockerfile` | صورة Railway: باكند فقط + ffmpeg + مستخدم غير جذري |
| `deploy/railway/entrypoint.sh` | يصلح ملكية الـ Volume (root) ثم يهبط الصلاحيات إلى `autoclip` (uid 10001) |
| `deploy/railway/start.sh` | تهيئة قاعدة البيانات، انتظار Redis، تشغيل Celery worker اختيارياً، ثم uvicorn على `$PORT` |
| `frontend/wrangler.jsonc` | إعداد نشر `frontend/dist` كأصول ثابتة على Cloudflare Workers |
| `frontend/src/utils/apiConfig.ts` | دعم `VITE_API_BASE_URL` (عنوان الـ API المطلق) |
| `.github/workflows/deploy-cloudflare.yml` | نشر تلقائي للواجهة على Cloudflare عند push إلى `main` |
| `.github/workflows/deploy-railway.yml` | نشر تلقائي للباكند على Railway عند push إلى `main` |
| `backend/app_factory.py` | خيار `AUTOCLIP_SERVE_FRONTEND_DIR` لتقديم الواجهة من نفس حاوية الباكند (بديل: كل شيء على Railway) |

---

## 1. Railway — الباكند

### 1.1 إنشاء المشروع و Redis

1. من <https://railway.com> أنشئ **New Project**.
2. داخل المشروع: **+ New** → **Database** → **Redis**.
3. سمّ الخدمة `Redis` (أو عدّل اسم المرجع في الخطوة 1.3).

### 1.2 إنشاء خدمة التطبيق

**+ New** → **GitHub Repo** → اختر المستودع الذي يحتوي هذا الكود. ثم في إعدادات الخدمة:

- **Root Directory**: اتركه فارغاً (جذر المستودع).
- لا تغيّر Build Command؛ البناء يحدث عبر Dockerfile الذي نحدده في المتغيرات.

### 1.3 متغيرات البيئة (Variables)

أضف هذه المتغيرات إلى خدمة التطبيق (Settings → Variables):

| المتغير | القيمة | لماذا |
| --- | --- | --- |
| `RAILWAY_DOCKERFILE_PATH` | `/deploy/railway/Dockerfile` | Railway يبحث افتراضياً عن `Dockerfile` في الجذر فقط |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | مرجع لمتغير خدمة Redis (اضغط “Add Reference”) |
| `AUTOCLIP_RUN_WORKER` | `true` | يشغّل Celery worker داخل نفس الحاوية (بدونه تبقى المشاريع «قيد الانتظار») |
| `AUTOCLIP_ALLOWED_ORIGINS` | `https://autoclip.<account>.workers.dev` | بدونها يرفض الباكند طلبات الكتابة القادمة من نطاق Cloudflare (403) |
| `ENVIRONMENT` | `production` | |
| `DEBUG` | `false` | |
| `LOG_LEVEL` | `INFO` | |
| `TZ` | `Asia/Shanghai` | الجدولة اليومية في Celery مضبوطة على هذا التوقيت |
| `LLM_PROVIDER` | `dashscope` أو `openai` أو `gemini` … | مزوّد النموذج المستخدم في التحليل |
| `API_MODEL_NAME` | `qwen-plus` مثلاً | اسم النموذج لدى المزوّد |
| `API_DASHSCOPE_API_KEY` | مفتاحك | مفتاح المزوّد (أو `API_OPENAI_API_KEY` / `API_GEMINI_API_KEY` …) |
| `AUTOCLIP_SERVE_FRONTEND_DIR` | لا تضبطه | تركه فارغاً لأن الواجهة على Cloudflare |

> `AUTOCLIP_ALLOWED_ORIGINS` يمكن تعديلها لاحقاً بعد أن تعرف نطاق Cloudflare النهائي. افصل بين
> المصادر بفاصلة، ويُهمَل الشرطة المائلة في النهاية: `https://a.example.com,https://b.example.com`.

### 1.4 Volume (تخزين دائم) — إلزامي

Settings → **Volumes** → **Add Volume**:

- **Mount Path**: `/app/data` (بالضبط؛ هو نفسه `AUTOCLIP_DATA_DIR` في الصورة).
- **Size**: حسب حجم الفيديوهات (10 غيغابايت فما فوق للاستخدام الجدي).

بدون Volume تُفقد قاعدة SQLite وكل الملفات المُصدَّرة عند كل إعادة نشر.

> لماذا خدمة واحدة للـ API والـ worker؟ لأن Railway تسمح بربط Volume واحد بخدمة واحدة فقط،
> وقاعدة SQLite وملفات المشاريع مشتركة بين الاثنين. لذلك يشغّل `start.sh` الاثنين في حاوية واحدة
> ويشتركان نفس `/app/data`. لا ترفع عدد النسخ (Replicas) فوق 1.

### 1.5 إعدادات النشر في اللوحة

Settings → **Deploy**:

| الإعداد | القيمة |
| --- | --- |
| Healthcheck Path | `/api/v1/health/` |
| Healthcheck Timeout | `300` (أو متغير `RAILWAY_HEALTHCHECK_TIMEOUT_SEC`) |
| Restart Policy | `On Failure` |
| Replicas | `1` |
| Watch Paths | `backend/**`, `deploy/railway/**`, `requirements.txt`, `init_database.py` (اختياري: يقلل عمليات البناء) |

### 1.6 النطاق العام والتحقق

Settings → **Networking** → **Generate Domain**. ستحصل على شيء مثل
`https://autoclip-api-production.up.railway.app`.

تحقّق:

```bash
curl -fsS https://autoclip-api-production.up.railway.app/api/v1/health/
# {"status":"healthy","timestamp":"...","version":"1.5.7"}

curl -fsS https://autoclip-api-production.up.railway.app/health
# {"status":"ok","mode":"web","version":"1.5.7"}
```

في سجلات Railway (Deploy Logs) يجب أن ترى:

```
[autoclip] Redis 连接成功
[autoclip] 启动 Celery worker（队列 celery,processing,video,notification,upload）
[autoclip] 启动 FastAPI：0.0.0.0:8000
```

إن ظهرت رسالة `Redis 不可用` فالمرجع `${{Redis.REDIS_URL}}` غير صحيح أو اسم خدمة Redis مختلف.

### 1.7 النشر من الطرفية (بدل ربط GitHub)

```bash
npm i -g @railway/cli
railway login
railway link            # اختر المشروع والبيئة
railway variables --set RAILWAY_DOCKERFILE_PATH=/deploy/railway/Dockerfile
railway variables --set AUTOCLIP_RUN_WORKER=true
railway up --service autoclip
```

---

## 2. Cloudflare — الواجهة

### 2.1 بناء الواجهة بعنوان الـ API الصحيح

`VITE_API_BASE_URL` متغيّر **بناء**، أي أن قيمته تُحقن داخل ملفات JS. بعد أي تغيير أعد البناء.

```bash
cd frontend
npm ci
VITE_API_BASE_URL="https://autoclip-api-production.up.railway.app/api/v1" npm run build
```

يجوز كتابة الدومين فقط (`https://autoclip-api-production.up.railway.app`) وسيُضاف `/api/v1` تلقائياً.
تأكد أن العنوان ظهر في المخرجات:

```bash
grep -ro "https://autoclip-api-production.up.railway.app" dist/assets | head -3
```

بدائل للقيم الاختيارية (كلها عامة وآمنة للعميل):

```bash
VITE_PUBLIC_POSTHOG_KEY=phc_xxx \
VITE_PUBLIC_POSTHOG_HOST=https://eu.i.posthog.com \
VITE_PUBLIC_SENTRY_DSN=https://xxx.ingest.sentry.io/yyy \
VITE_API_BASE_URL=https://autoclip-api-production.up.railway.app/api/v1 \
npm run build
```

### 2.2 النشر

```bash
cd frontend
npx wrangler login          # مرة واحدة
npm run deploy:cloudflare   # build + wrangler deploy
```

أول نشر يطبع نطاقاً مثل `https://autoclip.<account>.workers.dev`.

معاينة محليّة بنفس إعدادات Cloudflare (بدون نشر):

```bash
cd frontend
VITE_API_BASE_URL="https://autoclip-api-production.up.railway.app/api/v1" npm run preview:cloudflare
```

### 2.3 نطاق مخصّص (اختياري)

Cloudflare Dashboard → Workers & Pages → `autoclip` → Settings → **Domains & Routes** →
Add → Custom Domain، مثل `clips.example.com` (يجب أن يكون النطاق على نفس حساب Cloudflare).

### 2.4 ارجع إلى Railway وحدّث المصادر المسموحة

```
AUTOCLIP_ALLOWED_ORIGINS = https://autoclip.<account>.workers.dev,https://clips.example.com
```

بدون ذلك ستنجح قراءة البيانات (`GET`) لكن ستفشل عمليات الرفع/التصدير/الحفظ برسالة `403`.

> السبب في الكود: `backend/core/local_origin_guard.py` يرفض طلبات الكتابة التي تحمل `Origin`
> غير مسموح، لأن الباكند لا يملك تسجيل دخول — وهذا ما يمنع أي موقع آخر من استغلال مفتاح API الخاص بك.

---

## 3. نشر تلقائي عبر GitHub Actions (اختياري لكن مُستحسن)

### 3.1 Secrets و Variables المطلوبة

في المستودع: Settings → Secrets and variables → Actions.

| النوع | الاسم | القيمة |
| --- | --- | --- |
| Secret | `CLOUDFLARE_API_TOKEN` | توكن من Cloudflare بصلاحية **Workers Scripts: Edit** |
| Secret | `CLOUDFLARE_ACCOUNT_ID` | معرّف الحساب (يظهر في Workers overview) |
| Secret | `RAILWAY_TOKEN` | Project Token من Railway → Project Settings → Tokens |
| Variable | `AUTOCLIP_API_BASE_URL` | `https://autoclip-api-production.up.railway.app/api/v1` |
| Variable | `RAILWAY_SERVICE` | اسم أو معرّف خدمة Railway |
| Variable | `RAILWAY_ENVIRONMENT` | `production` |
| Variable (اختياري) | `VITE_PUBLIC_POSTHOG_KEY`, `VITE_PUBLIC_POSTHOG_HOST`, `VITE_PUBLIC_SENTRY_DSN` | التتبع/الأخطاء |

### 3.2 كيف يعمل

- `deploy-cloudflare.yml`: عند push إلى `main` يتغير فيه شيء داخل `frontend/` → يبني وينشر الواجهة.
- `deploy-railway.yml`: عند push إلى `main` يتغير فيه شيء في `backend/` أو `deploy/railway/` أو
  `requirements.txt` → ينفّذ `railway up`.

> **تحذير**: إذا فعّلت أيضاً «GitHub Auto-Deploy» داخل خدمة Railway، ستنفَّذ عمليتا نشر لكل push.
> اختر واحداً: إمّا تكامل Railway، أو الـ workflow — لا الاثنان.

للتشغيل اليدوي: Actions → اختر الـ workflow → **Run workflow**.

---

## 4. قائمة تحقّق بعد النشر

1. `https://autoclip.<account>.workers.dev` يفتح الواجهة (وليس شاشة بيضاء).
2. في DevTools → Network: طلبات `…/api/v1/...` تذهب إلى نطاق Railway وترجع `200`.
3. الصفحة الرئيسية تسرد المشاريع (فارغة طبعاً في أول مرة).
4. ارفع فيديو صغيراً + ملف SRT، وابدأ المعالجة.
5. في Railway → Volume: ظهرت مجلدات `projects/`، وفي Deploy Logs ظهرت مهام Celery (وليس رسائل
   «لا يوجد عامل»). إن بقيت الحالة «قيد الانتظار» فراجع `AUTOCLIP_RUN_WORKER=true`.

---

## 5. بديل: تشغيل كل شيء على Railway (واجهة + باكند في حاوية واحدة)

مناسب إن أردت خدمة واحدة فقط. استخدم `Dockerfile` الموجود في الجذر (يبني الواجهة أيضاً)، ثم:

| المتغير | القيمة |
| --- | --- |
| `RAILWAY_DOCKERFILE_PATH` | `Dockerfile` |
| `AUTOCLIP_SERVE_FRONTEND_DIR` | `/app/frontend/dist` |
| `AUTOCLIP_RUN_WORKER` | `true` |
| `RAILWAY_RUN_UID` | `0` (الصورة الأصلية تعمل بمستخدم غير جذري والـ Volume مملوك لـ root) |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` |
| `DATABASE_URL` | `sqlite:////app/data/autoclip.db` |
| `AUTOCLIP_DATA_DIR` | `/app/data` |

وبما أن هذه الصورة لا تشغّل Celery worker، عيّن **Start Command** في اللوحة:

```bash
celery -A backend.core.celery_app worker -l INFO -c 1 \
  -Q celery,processing,video,notification,upload &
exec python -m uvicorn backend.main:app --host 0.0.0.0 --port "${PORT:-8000}" --proxy-headers --forwarded-allow-ips='*'
```

بهذا الشكل تُقدَّم الواجهة من نفس النطاق، ولا حاجة لـ `AUTOCLIP_ALLOWED_ORIGINS` ولا لـ
`VITE_API_BASE_URL` (يبقى المسار النسبي `/api/v1`).

---

## 6. مشاكل شائعة

| العرض | السبب المرجّح | الحل |
| --- | --- | --- |
| فشل النشر: `Dockerfile not found` | Railway يبحث في الجذر | أضف `RAILWAY_DOCKERFILE_PATH=/deploy/railway/Dockerfile` |
| `Permission denied` / `sqlite3.OperationalError: unable to open database file` | Volume مملوك لـ root والحاوية تعمل بمستخدم غير جذري | تأكد أنك تستخدم `deploy/railway/Dockerfile` (entrypoint يصلح الملكية) وليس صورة أخرى |
| `Redis 不可用` ثم إعادة تشغيل متكررة | `REDIS_URL` غير مضبوط أو اسم الخدمة مختلف | استخدم “Add Reference” إلى خدمة Redis |
| Healthcheck فشل | الباكند لم يستمع على `$PORT` أو Redis لم يجهز | راجع Deploy Logs؛ زد `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| الواجهة تفتح لكن كل الطلبات تفشل / `Network Error` | بُنيت الواجهة بدون `VITE_API_BASE_URL` أو بعنوان خاطئ | أعد البناء بالقيمة الصحيحة (`grep` في `dist/assets` للتحقق) |
| قراءة تعمل وكتابة ترجع `403` | `AUTOCLIP_ALLOWED_ORIGINS` لا يحتوي نطاق الواجهة | أضف النطاق بالضبط (بدون `/` نهائي) وأعد النشر |
| المشاريع تبقى «قيد الانتظار» | لا يوجد Celery worker | `AUTOCLIP_RUN_WORKER=true` |
| المشروع يبقى «قيد الانتظار» رغم وجود العامل | مشكلة في الطوابير | يجب أن يستهلك العامل `celery,processing,video,notification,upload` (هذا مضبوط في `start.sh`) |
| بيانات اختفت بعد إعادة النشر | لا يوجد Volume أو مساره مختلف | Volume على `/app/data` بالضبط |
| رفع فيديو كبير يفشل | تجاوزت حدود الطلب في Worker الوسيط | هذا الدليل لا يستخدم وسيطاً؛ تأكد أن `VITE_API_BASE_URL` مطلق وليس `/api` نسبي |
| شاشة بيضاء بعد النشر | خطأ في بناء الواجهة أو مصدر CORS | افتح Console؛ أعد `npm run build` محلياً وتأكد من نجاحه |

---

## 7. ملاحظات أمنية وتكلفة

- **الباكند بلا تسجيل دخول.** أي شخص يعرف رابط Railway يستطيع استدعاء الـ API واستهلاك مفتاح
  النموذج الخاص بك (الحماية الحالية تمنع المتصفحات الأخرى فقط، لا `curl`). قبل فتح النظام للعامة:
  1. ضع **Cloudflare Access** على نطاق الواجهة،
  2. وأضف نطاقاً مخصصاً للـ API (`api.example.com`) عبر Cloudflare مع **Access** أو قاعدة WAF
     تقيّد الوصول (مثلاً حسب بلد/IP) بدل استخدام نطاق Railway الافتراضي،
  3. واحتفظ بمفاتيح قابلة للتدوير، ولا تضعها في الواجهة (الواجهة لا تحتاج أي مفتاح).
- **تكلفة**: Cloudflare Workers تخدم الأصول الثابتة مجاناً ضمن الحد اليومي. Railway فاتورة استخدام
  (CPU/RAM/Volume) — تشغيل ffmpeg لساعات هو البند الأكبر. أوقف الخدمة عند عدم الاستخدام إن كنت
  في خطة تجريبية.
- **نسخ احتياطي**: كل شيء في `/app/data` (SQLite + مشاريع + تصديرات). انسخ الـ Volume دورياً؛
  لا يوجد نسخ احتياطي تلقائي في هذه المعمارية.
- **الترقية**: تغيير رمز الحاوية/إعادة النشر يستخدم نفس الـ Volume، لكن ترقية الإصدارات الكبيرة
  قد تتضمن تعديلات قاعدة بيانات — راجع `CHANGELOG.md` وخذ نسخة من الـ Volume قبلها.

---

## 8. مرجع سريع للأوامر

```bash
# الباكند محلياً بنفس صورة Railway
docker build -f deploy/railway/Dockerfile -t autoclip-railway .
docker run --rm -p 8000:8000 -e REDIS_URL=redis://host.docker.internal:6379/0 autoclip-railway

# الواجهة: بناء ونشر
cd frontend
VITE_API_BASE_URL="https://autoclip-api-production.up.railway.app/api/v1" npm run build
npx wrangler deploy

# فحص سريع
curl -fsS https://autoclip-api-production.up.railway.app/api/v1/health/
```

روابط ذات صلة: [`DOCKER.md`](../DOCKER.md) (Docker Compose محلياً) ·
[`docs/USER_INSTALLATION_GUIDE.md`](USER_INSTALLATION_GUIDE.md) (تثبيت سطح المكتب).
