FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN python manage.py collectstatic --noinput

EXPOSE 8000

# Startup sequence:
#   1. migrate    — apply any pending DB migrations
#   2. createsuperuser — create the admin account if it doesn't exist yet.
#                  --noinput reads DJANGO_SUPERUSER_USERNAME/PASSWORD/EMAIL
#                  from env vars (injected from Secrets Manager by ECS).
#                  The '|| true' makes the command succeed even if the user
#                  already exists (every restart after the first).
#   3. gunicorn   — start the app server
CMD ["sh", "-c", "python manage.py migrate --noinput && python manage.py createsuperuser --noinput || true && gunicorn main.wsgi:application --bind 0.0.0.0:8000"]