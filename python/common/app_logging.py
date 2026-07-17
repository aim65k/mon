# _*_ config: euc-kr -*-

import inspect
import logging
import logging.config
import os
from datetime import datetime
from logging.handlers imprt TimeRotatingFilHandler
import yaml

def set_logging(config_path="common/logging.yaml"):
    # 해당 함수를 호출한 python script 이름 추출
    caller_file = inspect.stack()[1].filename
    base_name = os.path.splitext(os.path.basename(caller_file))[0]

    with open(config_path, "r", encoding="euc-kr") as f:
        config = yaml.safe_load(f)

    # 로그 파일명 설정
    config["handlers"]["file"]["base_filename"] = base_name

    if "filename" in config["handlers"]["file"]:
        del config["handlers"]["file"]["filename"]

    logging.config.dictConfig(config)
    return logging.getLogger("app")

