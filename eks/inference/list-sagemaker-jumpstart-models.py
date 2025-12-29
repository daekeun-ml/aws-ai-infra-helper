#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SageMaker JumpStart Model Discovery Tool
Lists and searches JumpStart models using boto3 API
"""

import argparse
import boto3
import sys
import json
from botocore.exceptions import ClientError, NoCredentialsError

def get_model_instance_types(sagemaker_client, model_id):
    """Get supported instance types for a specific model"""
    try:
        response = sagemaker_client.describe_hub_content(
            HubName='SageMakerPublicHub',
            HubContentType='Model',
            HubContentName=model_id
        )
        
        hub_content_doc = json.loads(response['HubContentDocument'])
        default_instance = hub_content_doc.get('DefaultInferenceInstanceType', 'N/A')
        supported_instances = hub_content_doc.get('SupportedInferenceInstanceTypes', [])
        
        return default_instance, supported_instances
    except Exception as e:
        print(f"Error getting instance types for {model_id}: {e}")
        return 'N/A', []

def list_all_models(sagemaker_client):
    """List all JumpStart models (names only)"""
    try:
        models = []
        next_token = None
        
        while True:
            kwargs = {
                'HubName': 'SageMakerPublicHub',
                'HubContentType': 'Model'
            }
            if next_token:
                kwargs['NextToken'] = next_token
                
            response = sagemaker_client.list_hub_contents(**kwargs)
            
            for content in response['HubContentSummaries']:
                models.append(content['HubContentName'])
            
            next_token = response.get('NextToken')
            if not next_token:
                break
                
        return models
    except ClientError as e:
        print(f"Error listing models: {e}")
        return []

def interactive_search(query):
    """Interactive search with model selection"""
    try:
        sagemaker = boto3.client('sagemaker')
        print(f"Search query: {query}")
        print("Searching models...")
        
        models = list_all_models(sagemaker)
        matching_models = [m for m in models if query.lower() in m.lower()]
        
        if not matching_models:
            print("No models found matching your search.")
            return
            
        print(f"\nFound {len(matching_models)} matches:")
        for i, model in enumerate(matching_models, 1):
            print(f"  {i}. {model}")
        
        print(f"  0. Exit")
        
        while True:
            try:
                choice = input(f"\nSelect a model (1-{len(matching_models)}, 0 to exit): ").strip()
                
                if choice == '0':
                    print("Exiting...")
                    return
                
                choice_num = int(choice)
                if 1 <= choice_num <= len(matching_models):
                    selected_model = matching_models[choice_num - 1]
                    print(f"\nSelected: {selected_model}")
                    
                    # Show instance types
                    print("Getting supported instance types...")
                    default_instance, supported_instances = get_model_instance_types(sagemaker, selected_model)
                    
                    print(f"\nModel: {selected_model}")
                    print(f"Default Instance: {default_instance}")
                    print(f"Supported Instances:")
                    for instance in supported_instances:
                        print(f"  - {instance}")
                    
                    return
                    
                else:
                    print(f"Invalid choice. Please enter a number between 1 and {len(matching_models)}, or 0 to exit.")
                    
            except ValueError:
                print("Invalid input. Please enter a number.")
            except KeyboardInterrupt:
                print("\nExiting...")
                return
                
    except NoCredentialsError:
        print("Error: AWS credentials not found. Please configure your AWS credentials.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

def search_models(query):
    """Search for models containing the query string (simple list)"""
    try:
        sagemaker = boto3.client('sagemaker')
        print(f"Search query: {query}")
        print("Searching models...")
        
        models = list_all_models(sagemaker)
        matching_models = [m for m in models if query.lower() in m.lower()]
        
        if not matching_models:
            print("No models found matching your search.")
            return
            
        print(f"Found {len(matching_models)} matches:")
        for model in matching_models:
            print(f"  {model}")
            
    except NoCredentialsError:
        print("Error: AWS credentials not found. Please configure your AWS credentials.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

def show_model_instances(model_id):
    """Show supported instance types for a specific model"""
    try:
        sagemaker = boto3.client('sagemaker')
        print(f"Getting instance types for: {model_id}")
        
        default_instance, supported_instances = get_model_instance_types(sagemaker, model_id)
        
        print(f"\nModel: {model_id}")
        print(f"Default Instance: {default_instance}")
        print(f"Supported Instances:")
        for instance in supported_instances:
            print(f"  - {instance}")
            
    except Exception as e:
        print(f"Error: {e}")

def count_models():
    """Count total number of models"""
    try:
        sagemaker = boto3.client('sagemaker')
        models = list_all_models(sagemaker)
        print(f"Total JumpStart models: {len(models)}")
    except Exception as e:
        print(f"Error counting models: {e}")

def main():
    parser = argparse.ArgumentParser(description='SageMaker JumpStart Model Discovery Tool')
    parser.add_argument('-l', '--list', action='store_true', help='List all JumpStart models')
    parser.add_argument('-c', '--count', action='store_true', help='Show model count only')
    parser.add_argument('-s', '--search', help='Search models (e.g., -s mistral)')
    parser.add_argument('-si', '--search-interactive', help='Interactive search with model selection')
    parser.add_argument('-i', '--instances', help='Show supported instances for a specific model')
    
    args = parser.parse_args()
    
    if args.count:
        count_models()
    elif args.search_interactive:
        interactive_search(args.search_interactive)
    elif args.search:
        search_models(args.search)
    elif args.instances:
        show_model_instances(args.instances)
    elif args.list:
        try:
            sagemaker = boto3.client('sagemaker')
            models = list_all_models(sagemaker)
            print(f"All {len(models)} JumpStart models:")
            for model in models:
                print(f"  {model}")
        except Exception as e:
            print(f"Error: {e}")
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
