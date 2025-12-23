FROM public.ecr.aws/deep-learning-containers/pytorch-training:2.6.0-gpu-py312-cu126-ubuntu22.04-ec2-v1.44

RUN apt-get update && apt-get install -y \
    openssh-server \
    pdsh \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    lightning \
    transformers \
    datasets \
    tokenizers

WORKDIR /workspace
COPY . /workspace/
