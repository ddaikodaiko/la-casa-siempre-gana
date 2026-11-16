FROM oven/bun:1.3-alpine
WORKDIR /app
COPY servidor.ts ./
ENV PORT=8080
EXPOSE 8080
USER bun
CMD ["bun", "servidor.ts"]
