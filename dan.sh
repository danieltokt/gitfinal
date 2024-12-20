#!/bin/bash 
 
# Логирование 
LOG_FILE="/var/log/deploy_django.log" 
echo "Начало развёртывания: $(date)" >> $LOG_FILE 

# Проверка прав суперпользователя 
if [ "$EUID" -ne 0 ]; then 
  echo "Пожалуйста, запустите скрипт с правами суперпользователя." | tee -a $LOG_FILE 
  exit 1 
fi 
 
# Параметры 
REPO_URL="https://github.com/DireSky/OSEExam.git" 
APP_DIR="/mnt/c/Users/user/Desktop/gitdan/OSEExam"  # Папка для клонирования 
APP_NAME="django_app" 
PYTHON_VERSION="python3" 
PROJECT_DIR="$APP_DIR/testPrj"  # Путь к проекту после клонирования 
 
# Установка необходимых пакетов 
apt update && apt install -y $PYTHON_VERSION $PYTHON_VERSION-venv git curl net-tools || { 
  echo "Ошибка установки пакетов" | tee -a $LOG_FILE 
  exit 1 
} 
 
# Клонирование репозитория 
if [ ! -d "$APP_DIR" ]; then 
  git clone $REPO_URL $APP_DIR || { 
    echo "Ошибка клонирования репозитория" | tee -a $LOG_FILE 
    exit 1 
  } 
else 
  echo "Директория $APP_DIR уже существует. Пропускаем клонирование." | tee -a $LOG_FILE 
fi 
 
# Создание подкаталога testPrj (если он еще не существует) 
if [ ! -d "$PROJECT_DIR" ]; then 
  echo "Создаём директорию для проекта: $PROJECT_DIR" | tee -a $LOG_FILE 
  mkdir -p "$PROJECT_DIR" || { 
    echo "Ошибка создания каталога для проекта $PROJECT_DIR" | tee -a $LOG_FILE 
    exit 1 
  } 
fi 
 
# Перемещаемся в каталог проекта 
cd $PROJECT_DIR || exit 
 
# Создание виртуального окружения 
if [ ! -d "venv" ]; then 
  $PYTHON_VERSION -m venv venv || { 
    echo "Ошибка создания виртуального окружения" | tee -a $LOG_FILE 
    exit 1 
  } 
fi 
source venv/bin/activate 
 
# Установка зависимостей 
if [ -f "$PROJECT_DIR/requirements.txt" ]; then 
  pip install Django 
  pip install gunicorn 
  pip install whitenoise  || { 
    echo "Ошибка установки зависимостей" | tee -a $LOG_FILE 
    deactivate 
    exit 1 
  } 
else 
  echo "Файл requirements.txt не найден" | tee -a $LOG_FILE 
fi 
 
deactivate 
 
# Миграции и сбор статических файлов 
source venv/bin/activate 
python manage.py migrate || { 
  echo "Ошибка выполнения миграций" | tee -a $LOG_FILE 
  deactivate 
  exit 1 
} 
python manage.py collectstatic --noinput || { 
  echo "Ошибка сборки статических файлов" | tee -a $LOG_FILE 
  deactivate 
  exit 1 
} 
deactivate 
 
# Добавление настроек в settings.py 
SETTINGS_FILE="$PROJECT_DIR/settings.py" 
 
# Добавление WhiteNoise 
if ! grep -q "whitenoise.middleware.WhiteNoiseMiddleware" "$SETTINGS_FILE"; then 
  echo "Добавляем настройки WhiteNoise в settings.py" | tee -a $LOG_FILE 
  sed -i "/'django.middleware.security.SecurityMiddleware'/a \ \ \ \ 'whitenoise.middleware.WhiteNoiseMiddleware'," "$SETTINGS_FILE" 
  echo -e "\n# Настройки WhiteNoise" >> "$SETTINGS_FILE" 
  echo "STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'" >> "$SETTINGS_FILE" 
  echo "STATIC_ROOT = os.path.join(BASE_DIR, 'static')" >> "$SETTINGS_FILE" 
fi 
 
# Добавление ALLOWED_HOSTS 
if ! grep -q "ALLOWED_HOSTS" "$SETTINGS_FILE"; then 
  echo "Добавляем ALLOWED_HOSTS в settings.py" | tee -a $LOG_FILE 
  echo -e "\n# Настройки ALLOWED_HOSTS" >> "$SETTINGS_FILE" 
  echo "ALLOWED_HOSTS = ['localhost', '127.0.0.1', '0.0.0.0', '*']" >> "$SETTINGS_FILE" 
fi 
 
# Добавление STATIC_ROOT (если еще не добавлено) 
if ! grep -q "STATIC_ROOT" "$SETTINGS_FILE"; then 
  echo "Добавляем STATIC_ROOT в settings.py" | tee -a $LOG_FILE 
  echo "STATIC_ROOT = os.path.join(BASE_DIR, 'static')" >> "$SETTINGS_FILE" 
fi 
 
# Функция для проверки и освобождения порта 
free_port() { 
  PORT=$1 
  PID=$(netstat -ltnp | grep ":$PORT " | awk '{print $7}' | cut -d'/' -f1) 
  if [ ! -z "$PID" ]; then 
    echo "Порт $PORT занят процессом с PID $PID. Завершаем процесс..." | tee -a $LOG_FILE 
    kill -9 $PID || { 
      echo "Не удалось завершить процесс, использующий порт $PORT" | tee -a $LOG_FILE 
      exit 1 
    } 
  fi 
} 
 
# Освобождаем порт 
PORT=8002 
free_port $PORT 
 
# Автоматический запуск Gunicorn 
start_gunicorn() { 
  while true; do 
    source venv/bin/activate 
    echo "Запуск Gunicorn..." | tee -a
$LOG_FILE 
    $PROJECT_DIR/venv/bin/gunicorn --workers 3 --bind 0.0.0.0:$PORT testPrj.wsgi:application || { 
      echo "Gunicorn завершил работу с ошибкой. Перезапуск..." | tee -a $LOG_FILE 
    } 
    deactivate 
    sleep 3 # Ожидание перед перезапуском, если Gunicorn упал 
  done 
} 
 
# Запуск Gunicorn в фоновом режиме 
start_gunicorn & 
 
# Проверка доступности приложения 
APP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT) 
if [ "$APP_STATUS" -eq 200 ]; then 
  echo "Приложение успешно развёрнуто и доступно по адресу http://localhost:$PORT" | tee -a $LOG_FILE 
else 
  echo "Ошибка: Приложение недоступно. Проверьте настройки." | tee -a $LOG_FILE 
fi 
 
exit 0