import os
import joblib
import numpy as np
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel


# On vérifie d'abord si MODEL_PATH est définie dans l'environnement (ex: Docker)
env_model_path = os.getenv("MODEL_PATH")

if env_model_path:
    # Cas Docker : la variable d'environnement est définie
    MODEL_PATH = Path(env_model_path)
else:
    # Cas local (uv) : on calcule le chemin par rapport au projet
    # Racine du projet (2 niveaux au-dessus de src/api/)
    ROOT_DIR = Path(__file__).resolve().parents[3]
    MODEL_PATH = ROOT_DIR / 'model' / 'model.joblib'

# Chargement du modèle entraîné
try:
    model = joblib.load(MODEL_PATH)
except FileNotFoundError:
    raise RuntimeError(f"Model file not found at {MODEL_PATH}.")
except Exception as e:
    raise RuntimeError(f"Error loading model: {e}")

app = FastAPI(
    title=" CoherentText? API",
    description="A simple API to predict if a text is coherent or just gibberish.",
    version="1.6.42",
)

# modèle de données pour la requête d'entrée
class Sentence(BaseModel):
    sentence: str

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "sentence": "fshf kjsfhsjkd",
                }
            ]
        }
    }

# endpoint de prédiction
@app.post("/predict")
def predict(features: Sentence):
    try:
        prediction = model.predict([features.sentence])
        prediction_proba = model.predict_proba([features.sentence])
        classes = ['anger', 'boredom', 'empty', 'enthusiasm', 'fun', 'happiness', 'hate', 'love',
                   'neutral', 'relief', 'sadness', 'surprise', 'worry']

        return {
            "prediction value": prediction[0],
            # "prediction_proba_dict": dict(zip(classes, prediction_proba.tolist()[0]))
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction error: {e}")
