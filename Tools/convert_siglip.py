"""Convert Google multilingual SigLIP into two Core ML embedding encoders.

Source model: google/siglip-base-patch16-256-multilingual (Apache-2.0)
Output is intentionally written outside the app bundle. Review model size and
distribution strategy before shipping it with the product.
"""

import json
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as functional
from transformers import AutoModel, AutoTokenizer


MODEL_ID = "google/siglip-base-patch16-256-multilingual"
IMAGE_SIZE = 256
OUTPUT = Path(__file__).resolve().parents[1] / "LocalModels" / "SigLIPMultilingual"


class ImageEncoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.vision = model.vision_model

    def forward(self, pixel_values):
        pixel_values = pixel_values * 2.0 - 1.0
        return functional.normalize(self.vision(pixel_values).pooler_output, dim=-1)


class TextEncoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.text = model.text_model

    def forward(self, input_ids):
        return functional.normalize(self.text(input_ids).pooler_output, dim=-1)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    model = AutoModel.from_pretrained(MODEL_ID).eval()
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    tokenizer_output = OUTPUT / "Tokenizer"
    tokenizer.save_pretrained(tokenizer_output)
    tokenizer_json = {
        "model": {
            "unk_id": tokenizer.sp_model.unk_id(),
            "vocab": [
                [tokenizer.sp_model.id_to_piece(index), tokenizer.sp_model.get_score(index)]
                for index in range(tokenizer.sp_model.vocab_size())
            ],
        }
    }
    (tokenizer_output / "tokenizer.json").write_text(
        json.dumps(tokenizer_json, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    image_encoder = torch.jit.trace(
        ImageEncoder(model).eval(),
        torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE),
    )
    image_model = ct.convert(
        image_encoder,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                scale=1.0 / 255.0,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="image_embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    image_model.author = "Google SigLIP, converted for PickPic"
    image_model.license = "Apache-2.0"
    image_model.save(OUTPUT / "SigLIPImageEncoder.mlpackage")

    text_encoder = torch.jit.trace(TextEncoder(model).eval(), torch.zeros((1, 64), dtype=torch.int64))
    text_model = ct.convert(
        text_encoder,
        inputs=[ct.TensorType(name="input_ids", shape=(1, 64), dtype=int)],
        outputs=[ct.TensorType(name="text_embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    text_model.author = "Google SigLIP, converted for PickPic"
    text_model.license = "Apache-2.0"
    text_model.save(OUTPUT / "SigLIPTextEncoder.mlpackage")

    print(f"Saved SigLIP encoders and tokenizer to {OUTPUT}")


if __name__ == "__main__":
    main()
