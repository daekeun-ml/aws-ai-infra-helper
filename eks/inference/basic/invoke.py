import boto3
import json

# Initialize SageMaker runtime client for inference
client = boto3.client('sagemaker-runtime')

# Configure your endpoint name here
# For FSx deployment: 'deepseek15b-fsx'
# For S3 deployment: 'deepseek15b' (or your custom endpoint name)
ENDPOINT_NAME = 'deepseek15b-fsx'

# Invoke the inference endpoint with streaming response
response = client.invoke_endpoint_with_response_stream(
    EndpointName=ENDPOINT_NAME,
    ContentType='application/json',
    Accept='application/json',
    Body=json.dumps({
        "inputs": "Hi, what can you help me with?",  # Your prompt here
        "parameters": {
            "stream": True  # Enable streaming for real-time response
        }
    })
)

# Process and display the streaming response
print(f"Response from endpoint '{ENDPOINT_NAME}':")
print("-" * 50)

for event in response['Body']:
    if 'PayloadPart' in event:
        # Decode and print each chunk of the response
        chunk = event['PayloadPart']['Bytes'].decode('utf-8')
        print(chunk, end='', flush=True)

print("\n" + "-" * 50)
print("Inference completed.")