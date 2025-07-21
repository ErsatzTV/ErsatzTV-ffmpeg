ARG BASE_IMAGE_TAG=7.1.1
FROM jasongdove/ersatztv-ffmpeg:${BASE_IMAGE_TAG}

RUN ["ffmpeg", "--help"]

CMD         ["--help"]
ENTRYPOINT  ["ffmpeg"]
