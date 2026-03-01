FROM alpine:3.20
RUN apk add --no-cache tini
COPY jfai /usr/local/bin/jfai
RUN chmod +x /usr/local/bin/jfai
EXPOSE 8080
ENTRYPOINT ["tini", "--"]
CMD ["jfai"]
