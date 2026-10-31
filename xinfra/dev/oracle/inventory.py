import os

hosts = [
    (
        "q1",
        {
            "ssh_hostname": os.environ["Q1_HOST"],
            "ssh_port": int(os.environ["Q1_PORT"]),
            "ssh_user": os.environ["Q1_USER"],
            "ssh_key": os.environ["Q1_KEY"],
        },
    )
]
