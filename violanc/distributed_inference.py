#!/usr/bin/env python3

from mpi4py import MPI
import torch
import cv2
import numpy as np
import sys
import time

# ============================================================
# MPI INIT
# ============================================================

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()

NUM_WORKERS = 4
FRAMES_PER_CHUNK = 16
IMG_SIZE = 112

MODEL_PATH = "hybrid_model3_torchscript_final.pt"

IMG_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMG_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# ============================================================
# MASTER FUNCTIONS
# ============================================================

def load_video_frames(video_path):

    cap = cv2.VideoCapture(video_path)

    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    frames = []

    while True:
        ret, frame = cap.read()

        if not ret:
            break

        frames.append(frame)

    cap.release()

    return frames


def build_chunks(frames):

    chunks = []

    for i in range(0, len(frames), FRAMES_PER_CHUNK):

        chunk = frames[i:i + FRAMES_PER_CHUNK]

        if len(chunk) < FRAMES_PER_CHUNK:
            pad = FRAMES_PER_CHUNK - len(chunk)
            chunk += [chunk[-1]] * pad

        chunks.append(chunk)

    return chunks


def preprocess_chunk(chunk):

    processed = []

    for frame in chunk:

        frame = cv2.resize(frame, (IMG_SIZE, IMG_SIZE))
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        frame = frame.astype(np.float32) / 255.0
        frame = (frame - IMG_MEAN) / IMG_STD

        frame = frame.transpose(2, 0, 1)

        processed.append(frame)

    processed = np.stack(processed, axis=0)

    return processed.astype(np.float32)


def aggregate_predictions(predictions):

    violence_scores = []
    non_violence_scores = []

    for pred, conf in predictions:

        if pred == 1:
            violence_scores.append(conf)
        else:
            non_violence_scores.append(conf)

    v_count = len(violence_scores)
    nv_count = len(non_violence_scores)

    if v_count >= nv_count:
        final_label = "VIOLENCE"
        confidence = np.mean(violence_scores) if violence_scores else 0
    else:
        final_label = "NON-VIOLENCE"
        confidence = np.mean(non_violence_scores) if non_violence_scores else 0

    return final_label, confidence


# ============================================================
# WORKER FUNCTION
# ============================================================

def worker_loop():

    print(f"[Worker {rank}] Loading TorchScript model...")

    model = torch.jit.load(MODEL_PATH, map_location="cpu")

    model.eval()

    print(f"[Worker {rank}] Model loaded.")

    num_rounds = comm.bcast(None, root=0)

    for _ in range(num_rounds):

        chunk = comm.scatter(None, root=0)

        tensor = torch.tensor(chunk)

        # (16,3,H,W) -> (1,3,16,H,W)
        tensor = tensor.permute(1,0,2,3).unsqueeze(0)

        with torch.no_grad():

            output = model(tensor)

            probs = torch.softmax(output, dim=1)

            confidence, prediction = torch.max(probs, dim=1)

        result = (
            int(prediction.item()),
            float(confidence.item())
        )

        comm.gather(result, root=0)


# ============================================================
# MASTER FUNCTION
# ============================================================

def master(video_path):

    t0 = time.time()

    print(f"\n[MASTER] Loading video: {video_path}")

    frames = load_video_frames(video_path)

    print(f"[MASTER] Total frames: {len(frames)}")

    chunks = build_chunks(frames)

    print(f"[MASTER] Total chunks: {len(chunks)}")

    preprocessed = [preprocess_chunk(c) for c in chunks]

    n_pad = (NUM_WORKERS - len(preprocessed) % NUM_WORKERS) % NUM_WORKERS

    if n_pad:
        preprocessed += [preprocessed[-1]] * n_pad

    num_real_chunks = len(preprocessed) - n_pad

    num_rounds = len(preprocessed) // NUM_WORKERS

    print(f"[MASTER] Scatter rounds: {num_rounds}")

    comm.bcast(num_rounds, root=0)

    all_predictions = []

    for r in range(num_rounds):

        start = r * NUM_WORKERS

        batch = preprocessed[start:start + NUM_WORKERS]

        scatter_data = [None] + batch

        print(f"\n[MASTER] Round {r+1}/{num_rounds}")

        comm.scatter(scatter_data, root=0)

        gathered = comm.gather(None, root=0)

        results = [x for x in gathered if x is not None]

        all_predictions.extend(results)

        for idx, (pred, conf) in enumerate(results):

            label = "VIOLENCE" if pred == 1 else "NON-VIOLENCE"

            print(
                f"  Worker {idx+1}: "
                f"{label} ({conf:.4f})"
            )

    all_predictions = all_predictions[:num_real_chunks]

    final_label, final_conf = aggregate_predictions(all_predictions)

    elapsed = time.time() - t0

    print("\n================================================")
    print(f"FINAL RESULT : {final_label}")
    print(f"CONFIDENCE   : {final_conf:.4f}")
    print(f"TIME         : {elapsed:.2f} sec")
    print("================================================\n")


# ============================================================
# MAIN
# ============================================================

if __name__ == "__main__":

    if size != 5:

        if rank == 0:
            print("Run with 5 MPI processes.")

        sys.exit()

    if rank == 0:

        if len(sys.argv) < 2:
            print("Usage:")
            print("mpirun -np 5 python distributed_inference.py video.mp4")
            sys.exit()

        video_path = sys.argv[1]

        master(video_path)

    else:

        worker_loop()