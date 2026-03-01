FROM alpine:3.20
COPY jfai /usr/local/bin/jfai
RUN chmod +x /usr/local/bin/jfai
EXPOSE 8080
ENTRYPOINT ["jfai"]
