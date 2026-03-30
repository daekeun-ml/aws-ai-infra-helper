#!/usr/bin/env python3
import argparse
import os
import subprocess
from datasets import load_dataset

# Dataset configurations (name, config, max_samples, dataset_type)
# dataset_type: 'pretrain' for continual pre-training, 'sft' for supervised fine-tuning
DATASETS = {
    "wikitext-2": ("wikitext", "wikitext-2-raw-v1", None, "pretrain"),  # Language modeling dataset (~36k samples)
    "wikitext-103": ("wikitext", "wikitext-103-raw-v1", 180000, "pretrain"),  # Large language modeling dataset (limited to 180k)
    "emotion": ("emotion", None, None, "sft"),  # Emotion classification with 6 emotions (~20k samples)
    "sst2": ("glue", "sst2", None, "sft"),  # Stanford Sentiment Treebank binary classification (~67k samples)
    "cola": ("glue", "cola", None, "sft"),  # Corpus of Linguistic Acceptability (~8.5k samples)
    "rte": ("glue", "rte", None, "sft"),  # Recognizing Textual Entailment (~2.5k samples)
    "imdb": ("imdb", None, None, "sft"),  # Movie review sentiment analysis (~50k samples)
    "ag_news": ("ag_news", None, None, "sft"),  # News categorization into 4 classes (~120k samples)
    "yelp_polarity": ("yelp_polarity", None, 100000, "sft"),  # Yelp review sentiment analysis (limited to 100k)
    "glan-qna-kr": ("daekeun-ml/GLAN-qna-kr-300k", None, 150000, "sft"),  # Korean Q&A dataset (limited to 150k)
}

def check_s3_exists(s3_path):
    """Check if S3 path exists"""
    try:
        result = subprocess.run(
            ["aws", "s3", "ls", s3_path], 
            capture_output=True, text=True, check=False
        )
        return result.returncode == 0 and result.stdout.strip()
    except:
        return False

def sync_to_s3(local_path, s3_path):
    """Sync local directory to S3"""
    try:
        print(f"🔄 Syncing {local_path} to {s3_path}...")
        result = subprocess.run(
            ["aws", "s3", "sync", local_path, s3_path, "--quiet"],
            check=True
        )
        print(f"✅ Successfully synced to {s3_path}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to sync to S3: {e}")
        return False

def prepare_dataset(name, dataset_config, max_samples=None, dataset_type="pretrain", output_dir=None):
    """Download and prepare a single dataset"""
    print(f"\n📥 Preparing {name} ({dataset_type})...")

    # Load dataset
    if dataset_config[1]:  # Has config
        dataset = load_dataset(dataset_config[0], dataset_config[1])
    else:
        dataset = load_dataset(dataset_config[0])

    # Format based on dataset type
    if dataset_type == "sft":
        if name == "glan-qna-kr":
            # Q&A format for instruction tuning
            def format_qa(example):
                return {"text": f"### Question\n{example['question']}\n\n### Answer\n{example['answer']}"}
            dataset = dataset.map(format_qa)
            dataset = dataset.remove_columns([col for col in dataset['train'].column_names if col != 'text'])

        elif name in ["emotion", "sst2", "cola", "rte", "imdb", "ag_news", "yelp_polarity"]:
            # Classification format for SFT
            def format_classification(example):
                if name == "emotion":
                    emotions = ["sadness", "joy", "love", "anger", "fear", "surprise"]
                    label = emotions[example['label']]
                    return {"text": f"Text: {example['text']}\nEmotion: {label}"}
                elif name == "sst2":
                    sentiment = "positive" if example['label'] == 1 else "negative"
                    return {"text": f"Review: {example['sentence']}\nSentiment: {sentiment}"}
                elif name == "cola":
                    acceptability = "acceptable" if example['label'] == 1 else "unacceptable"
                    return {"text": f"Sentence: {example['sentence']}\nAcceptability: {acceptability}"}
                elif name == "rte":
                    entailment = "entailment" if example['label'] == 0 else "not_entailment"
                    return {"text": f"Premise: {example['sentence1']}\nHypothesis: {example['sentence2']}\nEntailment: {entailment}"}
                elif name in ["imdb", "yelp_polarity"]:
                    sentiment = "positive" if example['label'] == 1 else "negative"
                    return {"text": f"Review: {example['text']}\nSentiment: {sentiment}"}
                elif name == "ag_news":
                    categories = ["World", "Sports", "Business", "Technology"]
                    category = categories[example['label']]
                    return {"text": f"Article: {example['text']}\nCategory: {category}"}
                return example

            dataset = dataset.map(format_classification)
            dataset = dataset.remove_columns([col for col in dataset['train'].column_names if col != 'text'])

    # For pretrain datasets, keep original format (text column should exist)

    # Limit samples if specified
    if max_samples and 'train' in dataset:
        original_size = len(dataset['train'])
        if original_size > max_samples:
            dataset['train'] = dataset['train'].select(range(max_samples))
            print(f"📊 Limited train samples: {original_size} → {max_samples}")

    # Save to output directory
    if output_dir is None:
        output_dir = f"./{name}-prepared"
    os.makedirs(output_dir, exist_ok=True)
    dataset.save_to_disk(output_dir)

    # Print stats
    for split in dataset.keys():
        print(f"📊 {split.capitalize()} samples: {len(dataset[split])}")

    return output_dir

def select_datasets():
    """Let user select which datasets to prepare"""
    print("📋 Available datasets:")
    dataset_list = list(DATASETS.keys())
    
    # Group by type
    pretrain_datasets = [name for name, config in DATASETS.items() if config[3] == "pretrain"]
    sft_datasets = [name for name, config in DATASETS.items() if config[3] == "sft"]
    
    print("\n🔤 Continual Pre-training datasets:")
    pretrain_indices = []
    for name in pretrain_datasets:
        idx = dataset_list.index(name) + 1
        pretrain_indices.append(idx)
        config = DATASETS[name]
        max_samples = f" (limited to {config[2]:,})" if config[2] else ""
        desc = get_description(name)
        print(f"  {idx}. {name}{max_samples} - {desc}")
    
    print("\n🎯 Supervised Fine-tuning datasets:")
    sft_indices = []
    for name in sft_datasets:
        idx = dataset_list.index(name) + 1
        sft_indices.append(idx)
        config = DATASETS[name]
        max_samples = f" (limited to {config[2]:,})" if config[2] else ""
        desc = get_description(name)
        print(f"  {idx}. {name}{max_samples} - {desc}")
    
    print(f"\n  {len(dataset_list) + 1}. All pretrain datasets")
    print(f"  {len(dataset_list) + 2}. All SFT datasets")
    print(f"  {len(dataset_list) + 3}. All datasets")
    
    while True:
        try:
            choice = input(f"\nSelect datasets (1-{len(dataset_list) + 3}, comma-separated): ").strip()
            
            if choice == str(len(dataset_list) + 1):
                return pretrain_datasets
            elif choice == str(len(dataset_list) + 2):
                return sft_datasets
            elif choice == str(len(dataset_list) + 3):
                return list(DATASETS.keys())
            
            indices = [int(x.strip()) - 1 for x in choice.split(',')]
            selected = [dataset_list[i] for i in indices if 0 <= i < len(dataset_list)]
            
            if selected:
                return selected
            else:
                print("❌ Invalid selection. Try again.")
        except (ValueError, IndexError):
            print("❌ Invalid input. Enter numbers separated by commas.")

def get_description(name):
    """Get dataset description"""
    descriptions = {
        "wikitext-2": "Language modeling dataset (~36k samples)",
        "wikitext-103": "Large language modeling dataset (limited to 180k)",
        "emotion": "Emotion classification with 6 emotions (~20k samples)",
        "sst2": "Stanford Sentiment Treebank binary classification (~67k samples)",
        "cola": "Corpus of Linguistic Acceptability (~8.5k samples)",
        "rte": "Recognizing Textual Entailment (~2.5k samples)",
        "imdb": "Movie review sentiment analysis (~50k samples)",
        "ag_news": "News categorization into 4 classes (~120k samples)",
        "yelp_polarity": "Yelp review sentiment analysis (limited to 100k)",
        "glan-qna-kr": "Korean Q&A dataset for instruction tuning (limited to 150k)"
    }
    return descriptions.get(name, "")

def main():
    """Main function to prepare datasets and optionally sync to S3"""
    parser = argparse.ArgumentParser(description="Prepare datasets for training")
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Download datasets directly to /fsx/data/[pretrain|sft]/ without S3 sync (useful for testing without DRA)"
    )
    parser.add_argument(
        "--local-base-dir",
        default="/fsx/data",
        help="Base directory for local-only mode (default: /fsx/data)"
    )
    args = parser.parse_args()

    s3_bucket = os.environ.get('S3_BUCKET_NAME')

    if args.local_only:
        print(f"📂 Local-only mode: datasets will be saved to {args.local_base_dir}/[pretrain|sft]/")
        print("⚠️  S3 sync and DRA setup are skipped.\n")
    elif not s3_bucket:
        print("⚠️  S3_BUCKET_NAME environment variable not set.")
        print("Options:")
        print("  1. Set S3 bucket:  export S3_BUCKET_NAME=your-bucket-name")
        print("  2. Local-only mode (no S3/DRA needed):  python3 prepare-datasets.py --local-only")
        return

    selected_datasets = select_datasets()

    if args.local_only:
        subprocess.run(["sudo", "mkdir", "-p", args.local_base_dir], check=False)
        subprocess.run(["sudo", "chown", "ubuntu:ubuntu", args.local_base_dir], check=False)
        print(f"\n🚀 Preparing {len(selected_datasets)} dataset(s) → {args.local_base_dir}/")
    else:
        print(f"\n🚀 Preparing {len(selected_datasets)} dataset(s) for S3 bucket: {s3_bucket}")

    for name in selected_datasets:
        try:
            config = DATASETS[name]
            dataset_type = config[3]

            if args.local_only:
                # Save directly to /fsx/data/pretrain/<name> or /fsx/data/sft/<name>
                dest_dir = os.path.join(args.local_base_dir, dataset_type, name)
                if os.path.exists(dest_dir) and os.listdir(dest_dir):
                    print(f"✅ {name} already exists at {dest_dir}, skipping...")
                    continue
                prepare_dataset(name, config, config[2], dataset_type, output_dir=dest_dir)
                subprocess.run(["sudo", "chown", "-R", "ubuntu:ubuntu", dest_dir], check=False)
                print(f"📍 Saved to {dest_dir}")
            else:
                s3_path = f"s3://{s3_bucket}/data/{dataset_type}/{name}/"
                if check_s3_exists(s3_path):
                    print(f"✅ {name} already exists in S3, skipping...")
                    continue
                local_dir = prepare_dataset(name, config, config[2], dataset_type)
                sync_to_s3(local_dir, s3_path)
                subprocess.run(["sudo", "chown", "-R", "ubuntu:ubuntu", local_dir], check=False)
                subprocess.run(["rm", "-rf", local_dir], check=False)
                print(f"🧹 Cleaned up local files for {name}")

        except Exception as e:
            print(f"❌ Failed to prepare {name}: {e}")

    print(f"\n🎉 Selected datasets prepared!")
    if args.local_only:
        print(f"📍 Available at: {args.local_base_dir}/[pretrain|sft]/")
    else:
        print(f"📍 Available at: s3://{s3_bucket}/data/[pretrain|sft]/")

if __name__ == "__main__":
    main()
