# النشر الكامل على Railway (واجهة + باكند في مكان واحد)

هذا هو المسار الأبسط والأسرع: خدمة واحدة على Railway تُقدّم **الواجهة والـ API معاً** على نفس
النطاق، بالإضافة إلى **Redis** (خدمة مُدارة داخل المشروع) و**Volume** للتخزين الدائم.

```
                 https://autoclip-production.up.railway.app
                                   │
                    ┌──────────────▼───────────────┐
                    │  حاوية واحدة (deploy/railway) │
                    │  uvicorn :$PORT               │
                    │   ├─ /            → الواجهة    │
                    │   ├─ /api/v1/*    → FastAPI    │
                    │   ├─ /docs        → Swagger    │
                    │   └─ Celery worker (نفس الحاوية)│
                    │  Volume → /app/data (SQLite…)  │
                    └──────────────┬───────────────┘
                                   │ REDIS_URL
                            ┌──────▼──────┐
                            │ Redis plugin │
                            └─────────────┘
```

لماذا بهذا الشكل؟

- **نفس النطاق** للواجهة والـ API: لا حاجة إلى CORS ولا إلى `VITE_API_BASE_URL`، ولا مشاكل
  «واجهة تعمل لكن كل الطلبات تفشل».
- **API + worker في حاوية واحدة**: Railway تربط Volume واحداً بخدمة واحدة، وقاعدة SQLite وملفات
  المشاريع والتصديرات كلها في `/app/data`، فلو فُصل الـ worker في خدمة ثانية لما رأى الملفات.
- **Redis كخدمة منفصلة**: هو الأنسب (يديره Railway، ولا يحتاج تخزيناً دائماً على الـ Volume).

الملفات المسؤولة في المستودع:

| الملف | الدور |
| --- | --- |
| `deploy/railway/Dockerfile` | بناء الواجهة (node) + الباكند (python) + ffmpeg/fonts، وتشغيلهما معاً |
| `deploy/railway/entrypoint.sh` | إصلاح ملكية الـ Volume (root) ثم الهبوط إلى uid 10001 |
| `deploy/railway/start.sh` | تهيئة قاعدة البيانات، انتظار Redis، تشغيل Celery worker، ثم uvicorn على `$PORT` |
| `backend/core/frontend_static.py` | تقديم ملفات الواجهة من الباكند عند ضبط `AUTOCLIP_SERVE_FRONTEND_DIR` |

> صورة المشروع تعمل افتراضياً بمستخدم غير جذري، والـ Volume على Railway يُركَّب مملوكاً لـ root،
> لذلك صورة Railway هنا تعمل كـ root للحظة ثم تهبط الصلاحيات. لو استخدمت `Dockerfile` الجذري
> بدلاً منها ستحتاج `RAILWAY_RUN_UID=0` وستفقد هذه الحماية.

---

## 1. إنشاء الخدمات

### 1.1 المشروع و Redis

1. <https://railway.com> → **New Project**.
2. **+ New** → **Database** → **Redis**. اترك الاسم `Redis` (يُستخدم في المرجع أدناه).

### 1.2 خدمة التطبيق

**+ New** → **GitHub Repo** → اختر المستودع (الفرع `main` بعد دمج التغييرات).
لا تضبط Root Directory.

### 1.3 المتغيرات (Settings → Variables)

الحد الأدنى المطلوب:

| المتغير | القيمة | ملاحظة |
| --- | --- | --- |
| `RAILWAY_DOCKERFILE_PATH` | `/deploy/railway/Dockerfile` | Railway يبحث افتراضياً عن `Dockerfile` في الجذر فقط |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | استخدم «Add Reference» لخدمة Redis |
| `LLM_PROVIDER` | `dashscope` (أو `openai` / `gemini` / `deepseek` …) | مزوّد النموذج |
| `API_MODEL_NAME` | `qwen-plus` مثلاً | اسم النموذج |
| `API_DASHSCOPE_API_KEY` | مفتاحك | أو `API_OPENAI_API_KEY` / `API_GEMINI_API_KEY` … حسب المزوّد |

قيم مضبوطة مسبقاً داخل الصورة (لا تحتاج إضافتها): `AUTOCLIP_DATA_DIR=/app/data`،
`DATABASE_URL=sqlite:////app/data/autoclip.db`، `AUTOCLIP_SERVE_FRONTEND_DIR=/app/frontend/dist`،
`AUTOCLIP_RUN_WORKER=true`، `PORT` (يوفّره Railway تلقائياً).

اختيارية لكن مفيدة:

| المتغير | القيمة | متى تحتاجه |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | جدولة Celery اليومية مضبوطة على هذا التوقيت |
| `ENVIRONMENT` / `DEBUG` | `production` / `false` | تنظيم اللوجات |
| `LOG_LEVEL` | `INFO` | تفاصيل اللوج |
| `CELERY_CONCURRENCY` | `1` | ارفعه فقط إذا كانت الحاوية تملك أنوية كثيرة |
| `UPLOAD_POST_API_KEY` / `UPLOAD_POST_USER` | — | النشر إلى TikTok/YouTube Shorts/IG |
| `AUTOCLIP_ALLOWED_ORIGINS` | `https://your-custom-domain.com` | فقط إن أضفت نطاقاً مخصّصاً واسماً مختلفاً، أو نشرت الواجهة على Cloudflare |

> المفاتيح تُحفَظ أيضاً من واجهة **الإعدادات** داخل التطبيق بعد أول دخول؛ لكن ضبط متغير بيئة واحد
> على الأقل يجعل التطبيق يعمل مباشرة بعد النشر.

### 1.4 Volume — إلزامي

Settings → **Volumes** → **Add Volume** → **Mount Path = `/app/data`** (بالضبط).
هنا تُخزَّن قاعدة SQLite وكل الفيديوهات والتصديرات وسجلات. بدون Volume يُفقد كل شيء عند كل نشر.

اختر حجماً واقعياً: فيديو 10 دقائق ≈ 100–300 م.ب، والتصديرات تضيف أمثال ذلك؛ ابدأ بـ 10 غ.ب.

### 1.5 إعدادات النشر (Settings → Deploy)

| الإعداد | القيمة |
| --- | --- |
| Healthcheck Path | `/api/v1/health/` |
| Healthcheck Timeout | `300` |
| Restart Policy | `On Failure` |
| Replicas | **`1`** |
| Watch Paths (اختياري) | `backend/**`, `frontend/**`, `deploy/railway/**`, `requirements.txt`, `init_database.py`, `src-tauri/tauri.conf.json` |

> Replicas = 1 شرط سلامة لا تحسين أداء: نسختان على نفس حجم SQLite = قفل/تلف محتمل،
> والـ Volume لا يشارَك بين نسختين.

### 1.6 النطاق والتحقق

Settings → **Networking** → **Generate Domain**. ثم:

```bash
DOMAIN=https://autoclip-production.up.railway.app
curl -fsS "$DOMAIN/api/v1/health/"   # {"status":"healthy",...}
curl -fsSI "$DOMAIN/" | head -1      # HTTP/2 200   ← الواجهة
```

سجلات النشر (Deploy Logs) يجب أن تحتوي:

```
[autoclip-entrypoint] 数据目录 /app/data 归属已交给 autoclip（uid 10001）
[autoclip] Redis 连接成功
[autoclip] 启动 Celery worker（队列 celery,processing,video,notification,upload）
[autoclip] 同一域名提供前端：/app/frontend/dist
[autoclip] 启动 FastAPI：0.0.0.0:8000
```

افتح الدومين في المتصفح → تظهر واجهة AutoClip، ومن `Settings` تُدخل مفتاح النموذج ثم تختبر الاتصال.

---

## 2. أول فيديو (تحقق وظيفي)

1. الصفحة الرئيسية → ارفع فيديو صغيراً (1–2 دقيقة) + ملف SRT، أو الصق رابط YouTube.
2. ابدأ المعالجة، وراقب:
   - شريط التقدم يتحرك (يعني إشارات Redis/التقدم تعمل)،
   - Deploy Logs تُظهر استلام مهمة في `processing`،
   - تبويب **Volume** يعرض `data/projects/<id>/…`.
3. إن بقيت الحالة «قيد الانتظار» فراجع `AUTOCLIP_RUN_WORKER=true` في Variables.

---

## 3. النشر من الطرفية (بدون ربط GitHub)

```bash
npm i -g @railway/cli
railway login
railway link                        # اختر المشروع والبيئة

railway variables --set RAILWAY_DOCKERFILE_PATH=/deploy/railway/Dockerfile
railway variables --set 'REDIS_URL=${{Redis.REDIS_URL}}'
railway variables --set LLM_PROVIDER=dashscope
railway variables --set API_MODEL_NAME=qwen-plus
railway variables --set API_DASHSCOPE_API_KEY=sk-...

railway up --service autoclip        # بناء ونشر مع متابعة اللوجات
railway domain                       # إنشاء/عرض النطاق العام
```

مع Project Token في CI:

```bash
RAILWAY_TOKEN=xxxx railway up --ci --service autoclip --environment production
```

---

## 4. نشر تلقائي عند كل push

الـ workflow جاهز: `.github/workflows/deploy-railway.yml`.

| النوع | الاسم | القيمة |
| --- | --- | --- |
| Secret | `RAILWAY_TOKEN` | Project Token (Railway → Project Settings → Tokens) |
| Variable | `RAILWAY_SERVICE` | اسم الخدمة أو معرّفها |
| Variable | `RAILWAY_ENVIRONMENT` | `production` |

يعمل عند تغيير أي ملف في `backend/` أو `frontend/` أو `deploy/railway/` أو `requirements.txt`.

> إن فعّلت أيضاً «GitHub Auto-Deploy» داخل خدمة Railway فسيُنشر مرتين لكل push. اختر واحداً.

---

## 5. قائمة تحقق بعد النشر

- [ ] `https://<domain>/` يفتح الواجهة (لا شاشة بيضاء، ولا صفحة 404 من Railway).
- [ ] `https://<domain>/api/v1/health/` يرجع `healthy`.
- [ ] `https://<domain>/docs` يفتح توثيق الـ API (مفيد للتحقق السريع).
- [ ] Deploy Logs: Redis + worker + uvicorn يعملون.
- [ ] Volume على `/app/data` ويحتوي `autoclip.db` و`projects/`.
- [ ] أول فيديو يصل إلى 100% ويظهر التصدير.
- [ ] إعدادات النموذج تعمل (زر اختبار الاتصال).

---

## 6. مشاكل شائعة (خاصة بالنشر الكامل)

| العرض | السبب المرجّح | الحل |
| --- | --- | --- |
| `Dockerfile not found` أو بناء غير متوقع | Railway يقرأ `Dockerfile` الجذري | `RAILWAY_DOCKERFILE_PATH=/deploy/railway/Dockerfile` |
| `Permission denied` / `unable to open database file` | Volume مملوك لـ root والحاوية بمستخدم غير جذري | تأكد أنك تستخدم صورة `deploy/railway` (entrypoint يصلح الملكية) |
| `Redis 不可用` ثم إعادة تشغيل | `REDIS_URL` غير مضبوط/مرجع خاطئ | «Add Reference» إلى خدمة Redis |
| Healthcheck فشل | الاستماع على منفذ غير `$PORT` | لا تضع `PORT` يدوياً؛ `start.sh` يستخدم القيمة التي يوفّرها Railway |
| الصفحة الرئيسية 404 أو أصول ناقصة | لم تُبنَ الواجهة داخل الصورة أو `AUTOCLIP_SERVE_FRONTEND_DIR` خاطئ | تحقق من وجود `/app/frontend/dist/index.html` في اللوج، وأعد البناء بدون `--cache` |
| واجهة قديمة بعد التحديث | كاش المتصفح (أسماء الأصول مُصدَّرة بهاش) | تحديث قسري؛ أو امسح Cloudflare cache إن وضعت CDN أمام الدومين |
| `403 请求来源不被允许` | أضفت نطاقاً مخصصاً أو واجهة خارجية | أضف النطاق إلى `AUTOCLIP_ALLOWED_ORIGINS`؛ للنشر الكامل على نفس النطاق لا تحتاجه |
| المشاريع «قيد الانتظار» | worker متوقف | `AUTOCLIP_RUN_WORKER=true` (وهو الافتراضي) وتحقق من عدم انهياره في اللوج |
| نفاد المساحة | Volume صغير | Railway → Volume → زيادة الحجم؛ احذف مشاريع قديمة من الواجهة |
| بطء شديد في المعالجة | CPU محدود في الخطة | ارفع خطة الخدمة، أو خفّض `CELERY_CONCURRENCY` إلى 1 (الافتراضي) |
| إعادة تشغيل متكررة | OOM أثناء ffmpeg | زد الذاكرة (2 غ.ب أو أكثر للفيديوهات الطويلة) أو قلّل جودة/طول المادة |

---

## 7. الأمان والتكلفة والنسخ الاحتياطي

- **لا يوجد تسجيل دخول** في الباكند: من يعرف الرابط يستطيع استدعاء الـ API واستهلاك مفتاح النموذج.
  قبل مشاركة الرابط مع آخرين: ضع **Cloudflare Access** أو **basic auth** على مستوى النطاق
  (أمام Railway)، أو استخدم نطاقاً مخصصاً مع قيد WAF. الحماية الحالية في الكود تمنع فقط مواقع
  الويب الأخرى من قراءة الـ API عبر متصفح المستخدم، ولا تمنع `curl`.
- **التكلفة**: Railway تحسب CPU/RAM/Volume زمنياً. المعالجة (ffmpeg) هي البند الأكبر. في خطة
  الاستخدام، أوقف الخدمة عند عدم الحاجة (Settings → Danger → Remove/Stop) بدل تركها تعمل.
- **الذاكرة**: 2 غ.ب كافية لفيديوهات قصيرة؛ الفيديوهات الطويلة والتصدير 1080p تحتاج أكثر.
- **النسخ الاحتياطي**: كل شيء في `/app/data`. خذ نسخة دورية (مثلاً `railway run tar czf - /app/data > backup.tgz`)
  قبل أي ترقية كبيرة، وراجع `CHANGELOG.md`.
- **الترقية**: أعد النشر بنفس الـ Volume؛ تعديلات مخطط قاعدة البيانات تُنفَّذ عند بدء التشغيل
  (`init_database.py` + `create_all`).

---

## 8. بديل: الواجهة على Cloudflare والـ API على Railway

إن أردت تسريع تحميل الواجهة عبر شبكة Cloudflare، راجع
[DEPLOY_CLOUDFLARE_RAILWAY_AR.md](DEPLOY_CLOUDFLARE_RAILWAY_AR.md). في هذه الحالة:

- استخدم نفس صورة `deploy/railway` لكن اضبط `AUTOCLIP_SERVE_FRONTEND_DIR=` (فارغاً) إن أردت API فقط،
- واضبط `AUTOCLIP_ALLOWED_ORIGINS` بنطاق Cloudflare،
- وابنِ الواجهة على Cloudflare بـ `VITE_API_BASE_URL=https://<railway-domain>/api/v1`.

> لا يمكن فصل Celery worker في خدمة Railway ثانية مع SQLite على Volume واحد؛ لتقسيم حقيقي
> تحتاج Postgres مُداراً + تخزين كائنات (S3/R2) وتعديل الإعدادات.

---

## 9. أوامر مرجعية

```bash
# بناء الصورة محلياً وتشغيلها بنفس إعدادات Railway
docker build -f deploy/railway/Dockerfile -t autoclip-full .
docker run --rm -p 8000:8000 \
  -e REDIS_URL=redis://host.docker.internal:6379/0 \
  -v "$PWD/.local-data:/app/data" \
  autoclip-full
# ثم: http://localhost:8000  (الواجهة) · http://localhost:8000/docs  (API)

# تشخيص على Railway
railway logs --service autoclip
railway ssh --service autoclip           # أو: railway run bash
```

روابط: [Docker محلياً](../DOCKER.md) · [دليل التثبيت](USER_INSTALLATION_GUIDE.md) ·
[إعداد النماذج](AI_MODEL_CONFIGURATION.md) · [الأسئلة الشائعة](FAQ.md).
