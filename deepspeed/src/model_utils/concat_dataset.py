from torch.utils.data import Dataset


class ConcatTokensDataset(Dataset):
    def __init__(self, dataset, tokenizer, max_length=2048):
        self.dataset = list(dataset)  # Convert streaming to list
        self.tokenizer = tokenizer
        self.max_length = max_length
        
    def __len__(self):
        return len(self.dataset)
    
    def __getitem__(self, idx):
        item = self.dataset[idx]
        if isinstance(item, dict) and 'text' in item:
            text = item['text']
        else:
            text = str(item)
        
        tokens = self.tokenizer(
            text,
            truncation=True,
            max_length=self.max_length,
            return_tensors="pt"
        )
        return tokens.input_ids.squeeze(0)
