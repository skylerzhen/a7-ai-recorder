# A7 AI 后端容器:node 22 + ffmpeg(/process、/stream 都依赖 ffmpeg;宿主无 ffmpeg,内置进镜像)。
FROM node:22-bookworm-slim

# 国内构建提速:Debian APT 换阿里云镜像(兼容 deb822 / 旧 sources.list 两种格式)。
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
      sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list; \
    fi

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先装依赖(利用缓存)。tsx 是 devDependency 运行所需,故装全量;npm 走 npmmirror 提速。
COPY package.json package-lock.json ./
RUN npm ci --registry=https://registry.npmmirror.com

COPY . .

ENV PORT=8787
EXPOSE 8787

# npm start = tsx src/server.ts(无构建步,直跑 TS)
CMD ["npm", "start"]
