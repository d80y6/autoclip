# AutoClip — نشر كامل على Railway (واجهة + باكند في حاوية واحدة)
#
# المراحل:
#   1. frontend-builder : npm ci + vite build → /app/frontend/dist
#   2. backend-builder  : pip install -r requirements.txt
#   3. runtime          : uvicorn يقدّم /api/* و /health و(اختيارياً) الواجهة من نفس النطاق
#
# لماذا حاوية واحدة للـ API والـ worker؟
#   Railway تربط Volume واحداً بخدمة واحدة. قاعدة SQLite وملفات المشاريع والتصديرات كلها في
#   /app/data، فلا يمكن فصل الـ worker في خدمة ثانية إلا بتحويل التخزين إلى مشترك (Postgres + S3).
#
# مسار Dockerfile غير افتراضي (deploy/railway/Dockerfile)، لذلك يجب ضبط المتغير:
#   RAILWAY_DOCKERFILE_PATH=/deploy/railway/Dockerfile

# ---------------------------------------------------------------- 1. الواجهة
FROM node:20-slim AS frontend-builder

WORKDIR /app/frontend

# نفس أدوات البناء التي تستخدمها صورة المشروع الأصلية (بعض الحزم تحتاج node-gyp).
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      make \
      g++ \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --fund=false

COPY frontend/ ./
# vite.config.ts يقرأ نسخة التطبيق من هذا الملف (وإلا يفشل البناء).
COPY src-tauri/tauri.conf.json /app/src-tauri/tauri.conf.json

# هذه القيم تُحقن وقت البناء. اتركها فارغة للنشر الكامل على Railway:
# الواجهة والباكند على نفس النطاق، فالمسار النسبي /api/v1 هو الصحيح.
# (متغيرات Railway تصل إلى البناء كـ build args فقط إذا صُرّح عنها بـ ARG هنا.)
ARG VITE_API_BASE_URL=""
ARG VITE_PUBLIC_POSTHOG_KEY=""
ARG VITE_PUBLIC_POSTHOG_HOST=""
ARG VITE_PUBLIC_SENTRY_DSN=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_PUBLIC_POSTHOG_KEY=$VITE_PUBLIC_POSTHOG_KEY \
    VITE_PUBLIC_POSTHOG_HOST=$VITE_PUBLIC_POSTHOG_HOST \
    VITE_PUBLIC_SENTRY_DSN=$VITE_PUBLIC_SENTRY_DSN

RUN npm run build && test -f dist/index.html

# ---------------------------------------------------------------- 2. الباكند
FROM python:3.11-slim AS backend-builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------- 3. الصورة النهائية
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    AUTOCLIP_DATA_DIR=/app/data \
    DATABASE_URL=sqlite:////app/data/autoclip.db \
    LOG_FILE=/app/data/autoclip.log \
    AUTOCLIP_SERVE_FRONTEND_DIR=/app/frontend/dist \
    AUTOCLIP_RUN_WORKER=true \
    PORT=8000

# ffmpeg/ffprobe: القص والتصدير. util-linux: setpriv (السماح بالهبوط من root إلى autoclip).
# fonts-noto-cjk: ترجمة/رسم النصوص الصينية في الفيديو (نفس ما يثبّته CI).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg \
      curl \
      util-linux \
      ca-certificates \
      fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=backend-builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=backend-builder /usr/local/bin /usr/local/bin
COPY --from=frontend-builder /app/frontend/dist /app/frontend/dist

COPY backend/ ./backend/
COPY scripts/ ./scripts/
COPY init_database.py ./
COPY deploy/railway/entrypoint.sh /usr/local/bin/autoclip-entrypoint
COPY deploy/railway/start.sh /usr/local/bin/autoclip-start

# uid/gid ثابتان (10001) حتى تعمل إصلاحات ملكية الـ Volume على كل إعادة نشر.
RUN chmod +x /usr/local/bin/autoclip-entrypoint /usr/local/bin/autoclip-start \
    && groupadd -r --gid 10001 autoclip \
    && useradd -r --uid 10001 --gid autoclip --home-dir /app autoclip \
    && mkdir -p /app/data/projects /app/data/uploads /app/data/temp /app/data/output /app/logs \
    && chown -R autoclip:autoclip /app

EXPOSE 8000

# لا نضع HEALTHCHECK هنا: Railway يستخدم healthcheckPath من إعدادات الخدمة.
ENTRYPOINT ["autoclip-entrypoint"]
CMD ["api"]
