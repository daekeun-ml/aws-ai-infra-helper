import boto3
import json

ENDPOINT_NAME = "deepseek7b-endpoint"
client = boto3.client("sagemaker-runtime")

payload = {
    "model": "/opt/ml/model",
    "messages": [
        {"role": "user", "content": "What is machine learning?"}
    ],
    "max_tokens": 150,
    "temperature": 0.2
}

response = client.invoke_endpoint(
    EndpointName=ENDPOINT_NAME,
    ContentType="application/json",
    Body=json.dumps(payload)
)

result = json.loads(response["Body"].read().decode())
print("=========================================")
print("[JSON Response]")
print(json.dumps(result, indent=2, ensure_ascii=False))

if "choices" in result and len(result["choices"]) > 0:
    message = result["choices"][0]["message"]["content"]
    print("=========================================")
    print(f"[Generated Text]\n{message}")
