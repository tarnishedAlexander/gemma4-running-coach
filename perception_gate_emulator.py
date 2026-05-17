import time
import random

def get_mock_gate_data():
    """Simulates the output from Apple LiDAR Depth Map and MobileCLIP."""
    # Simulate a person walking. Most of the time, the path is clear.
    # We create a 25% chance of a hazard appearing for the simulation.
    is_hazard = random.random() < 0.25 
    
    if is_hazard:
        depth_meters = round(random.uniform(0.5, 1.9), 1) # Hazard is close
        hazard_types = ["a curb or step", "a pothole", "a crack in concrete", "a dangerous obstacle in the path"]
        top_label = random.choice(hazard_types)
        hazard_score = round(random.uniform(0.35, 0.85), 2)
        safe_score = round(random.uniform(0.05, 0.20), 2)
    else:
        depth_meters = round(random.uniform(2.5, 5.0), 1) # Path is clear or objects are far
        top_label = "normal pavement"
        hazard_score = round(random.uniform(0.05, 0.25), 2)
        safe_score = round(random.uniform(0.50, 0.95), 2)
        
    return depth_meters, top_label, hazard_score, safe_score

def get_system_prompt():
    return """You are a navigation assistant for a visually impaired person.
You receive metadata from a local hazard gate (which has pre-processed the camera frame).
Look at the metadata and give concise safety guidance in one short sentence.
IMPORTANT: Respond ONLY with the spoken sentence. Do not use any markdown formatting, pleasantries, or chain of thought reasoning."""

def simulate_llm_response(prompt):
    """Sends the gate metadata to Gemma 4 via Ollama."""
    import ollama
    try:
        start_time = time.perf_counter()
        
        # Note: Hazard warnings should be instantaneous and stateless.
        # We do not use conversational memory here, because the user just needs immediate physics advice.
        response = ollama.chat(model='gemma4:e2b', messages=[
            {'role': 'system', 'content': get_system_prompt()},
            {'role': 'user', 'content': prompt}
        ])
        end_time = time.perf_counter()
        
        return {
            "text": response['message']['content'],
            "llm_time": end_time - start_time,
            "eval_tokens": response.get('eval_count', 0)
        }
    except Exception as e:
        return {"text": f"[Ollama Error: {str(e)}]", "llm_time": 0, "eval_tokens": 0}

def main():
    print("🦯 Starting MobileCLIP + Depth Gate Emulator...")
    print("This script emulates the iOS Perception Gate. It runs a fast loop every 1 second.")
    print("Gemma 4 will stay ASLEEP to save battery, and ONLY wake up if a hazard is detected.\n")
    print("-" * 70)
    
    try:
        while True:
            # 1. Fast Perception Loop (MobileCLIP + LiDAR)
            depth_meters, top_label, hazard_score, safe_score = get_mock_gate_data()
            
            # The EXACT gate logic from your MVP document:
            callGemma = (depth_meters < 2.0) and (hazard_score > 0.30) and (hazard_score > safe_score + 0.08)
            
            if not callGemma:
                print(f"✅ [Gate Closed] Depth: {depth_meters}m | Label: '{top_label}' | Gemma is sleeping 💤")
                time.sleep(1) # Fast loop
                continue
                
            # --- HAZARD DETECTED! TRIGGER GEMMA ---
            print("\n" + "🚨" * 30)
            print("🚨 HAZARD GATE TRIGGERED! WAKING UP GEMMA 4...")
            print(f"   - Estimated distance: {depth_meters}m")
            print(f"   - Top label: '{top_label}'")
            print(f"   - Hazard score: {hazard_score} (Safe score: {safe_score})")
            
            prompt = f"""[IMAGE: full 1080p camera frame]

Local hazard gate detected:
- region: bottom-center of frame
- estimated distance: {depth_meters}m
- top label: "{top_label}"
- MobileCLIP score: {hazard_score}

Look at the metadata and give concise safety guidance in one sentence."""
            
            result = simulate_llm_response(prompt)
            
            print("\n\033[92m" + f"🗣️ Assistant says: \"{result['text']}\"" + "\033[0m")
            
            if result['llm_time'] > 0:
                speed = result['eval_tokens'] / result['llm_time']
                print(f"⏱️ LLM Latency: {result['llm_time']:.2f}s | Speed: {speed:.1f} tok/s")
                
            print("🚨" * 30 + "\n")
            
            # Pause slightly longer after issuing a warning so we don't spam the user
            time.sleep(3) 
            
    except KeyboardInterrupt:
        print("\n\nExiting emulator...")

if __name__ == "__main__":
    main()
