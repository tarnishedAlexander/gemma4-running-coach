import time
import random
import ollama

def get_running_metrics():
    minutes = random.randint(6, 9)
    seconds = random.randint(0, 59)
    pace = f"{minutes}:{seconds:02d} /mi"
    cadence = random.randint(150, 180)
    hr = random.randint(130, 190)
    elevation = random.randint(-5, 15)
    power = random.randint(150, 350)
    stride = round(random.uniform(0.8, 1.4), 2)
    return pace, cadence, hr, elevation, power, stride

def get_hazard_data():
    # Realistic 2% chance per second. Hazards will only appear rarely!
    is_hazard = random.random() < 0.02 
    if is_hazard:
        depth = round(random.uniform(0.5, 1.9), 1)
        label = random.choice(["a deep pothole", "a curb", "an e-scooter abandoned on the path"])
        score = round(random.uniform(0.40, 0.85), 2)
        safe = round(random.uniform(0.05, 0.20), 2)
    else:
        depth = 3.0
        label = "clear path"
        score = 0.1
        safe = 0.8
    return depth, label, score, safe

def simulate_llm(chat_history):
    start = time.perf_counter()
    try:
        response = ollama.chat(model='gemma4:e2b', messages=chat_history)
        end = time.perf_counter()
        return {
            "text": response['message']['content'],
            "llm_time": end - start,
            "prompt_tokens": response.get('prompt_eval_count', 0),
            "eval_tokens": response.get('eval_count', 0)
        }
    except Exception as e:
        return {"text": f"[Ollama Error: {str(e)}]", "llm_time": 0, "prompt_tokens": 0, "eval_tokens": 0}

def main():
    print("+ COMBINED EMULATOR (Running Coach + Hazard Gate)\n")
    print("This simulates the exact Multi-Threaded iOS Architecture:")
    print(" - Thread 1: Camera/MobileCLIP runs every 1 second in the background.")
    print(" - Thread 2: CoreBluetooth/RunMetrics runs every 15 seconds.")
    print(" - Shared Context Window allows Gemma 4 to understand both instantly!\n")
    
    system_prompt = """You are an elite running coach and a safety navigation assistant. 
1. For regular running metrics, give ONE short, conversational sentence of coaching feedback. You MUST naturally include 1 or 2 of their current metrics (like their exact Heart Rate, Pace, or Cadence) in the sentence to make it personalized.
2. If a CRITICAL HAZARD alert appears, drop everything and warn them immediately. Your warning MUST be ONE sentence, and MUST explicitly state the hazard's exact distance, and either their current pace or heart rate.
IMPORTANT: Respond ONLY with the spoken response. Do not use markdown."""

    chat_history = [{'role': 'system', 'content': system_prompt}]
    
    last_coach_time = time.time()
    coach_interval = 10.0 # Shortened to 10s for simulation purposes
    
    try:
        while True:
            time.sleep(1) # Fast perception loop (1Hz)
            current_time = time.time()
            
            # 1. Check Hazard Gate (High Priority Background Thread)
            depth, label, score, safe = get_hazard_data()
            if depth < 2.0 and score > 0.3 and score > safe + 0.08:
                print("\n" + "!" * 25)
                print(" 1. GATHERING SENSOR INFO (Emulated Hazard Gate):")
                print(f"   - Estimated distance: {depth}m")
                print(f"   - Top label: '{label}'")
                print(f"   - MobileCLIP score: {score}")
                
                # Fetch the latest running metrics so the safety warning is context-aware!
                pace, cadence, hr, elevation, power, stride = get_running_metrics()
                
                urgent_msg = f"""[CRITICAL ALERT FROM PERCEPTION GATE]
Local hazard gate detected:
- estimated distance: {depth}m
- top label: "{label}"
- MobileCLIP score: {score}

Current Runner Status:
- Pace: {pace}
- Heart Rate: {hr} BPM
- Cadence: {cadence} spm

Look at the metadata. Combine the hazard warning with their current running speed/status and give a highly informative safety warning that explicitly mentions the distance to the hazard, their pace, and their heart rate."""

                chat_history.append({'role': 'user', 'content': urgent_msg})
                
                print("\n 2. NEW MESSAGE APPENDED TO CONTEXT:")
                print("\033[90m" + urgent_msg + "\033[0m")
                
                print(f"\n 3. LLM OUTPUT (Memory Size: {len(chat_history)} messages):")
                result = simulate_llm(chat_history)
                chat_history.append({'role': 'assistant', 'content': result['text']})
                
                print(f"\033[91m Gemma says: \"{result['text']}\"\033[0m")
                
                if result['llm_time'] > 0:
                    speed = result['eval_tokens'] / max(result['llm_time'], 0.001)
                    print("\n 4. PERFORMANCE METRICS:")
                    print(f"   - LLM Response Time: {result['llm_time']:.2f} seconds")
                    print(f"   - Tokens Used: {result['prompt_tokens']} prompt + {result['eval_tokens']} generated")
                    print(f"   - Speed: {speed:.1f} tok/sec")
                    
                print("" * 25)
                
                # Reset coach timer so we don't immediately nag them about their pace after a hazard
                last_coach_time = current_time
                time.sleep(2) 
                
            # 2. Check Running Coach (Low Priority 15s Loop)
            elif current_time - last_coach_time >= coach_interval:
                print("\n" + "-" * 50)
                print(" [10s Loop] Gathering Running Metrics...")
                sensor_start = time.perf_counter()
                pace, cadence, hr, elevation, power, stride = get_running_metrics()
                sensor_time = time.perf_counter() - sensor_start
                
                print("\n 1. GATHERING SENSOR INFO (Emulated):")
                print(f"   - Heart Rate: {hr} BPM")
                print(f"   - GPS Pace: {pace}")
                print(f"   - Motion Cadence: {cadence} spm")
                print(f"   - Elevation Change: {elevation} meters")
                print(f"   - Running Power: {power} W")
                print(f"   - Stride Length: {stride} m")
                print(f"     Sensor data collected in: {sensor_time:.5f} seconds")
                
                metrics_msg = f"""Current Metrics:
Heart Rate: {hr} BPM
Pace: {pace}
Cadence: {cadence} steps per minute
Elevation Change: {elevation} meters
Running Power: {power} W
Stride Length: {stride} m"""

                chat_history.append({'role': 'user', 'content': metrics_msg})
                
                print("\n 2. NEW MESSAGE APPENDED TO CONTEXT:")
                print("\033[90m" + metrics_msg + "\033[0m")
                
                print(f"\n 3. LLM OUTPUT (Memory Size: {len(chat_history)} messages):")
                result = simulate_llm(chat_history)
                chat_history.append({'role': 'assistant', 'content': result['text']})
                
                print(f"\033[94m Coach says: \"{result['text']}\"\033[0m")
                
                if result['llm_time'] > 0:
                    speed = result['eval_tokens'] / max(result['llm_time'], 0.001)
                    print("\n 4. PERFORMANCE METRICS:")
                    print(f"   - LLM Response Time: {result['llm_time']:.2f} seconds")
                    print(f"   - Tokens Used: {result['prompt_tokens']} prompt + {result['eval_tokens']} generated")
                    print(f"   - Speed: {speed:.1f} tok/sec")
                    
                print("-" * 50)
                
                last_coach_time = current_time
                
            # Keep memory bounded
            if len(chat_history) > 11:
                chat_history.pop(1)
                chat_history.pop(1)
                
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
