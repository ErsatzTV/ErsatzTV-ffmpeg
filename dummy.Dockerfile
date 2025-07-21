FROM jasongdove/ersatztv-ffmpeg:7.1.1

RUN ["ffmpeg", "--version"]

CMD         ["--help"]
ENTRYPOINT  ["ffmpeg"]
