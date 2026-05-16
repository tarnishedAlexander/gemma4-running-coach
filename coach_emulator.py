import time
import random

def get_mock_sensor_data():
    """Simulates grabbing data from GPS and Pedometer."""
    # Random pace between 6:00/mi and 9:59/mi
    minutes = random.randint(6, 9)
    seconds = random.randint(0, 59)
    pace = f"{minutes}:{seconds:02d} /mi"
    
    # Random cadence between 150 and 180 spm
    cadence = random.randint(150, 180)
    
    # Random heart rate between 130 and 190 bpm
    hr = random.randint(130, 190)
    
    # Random elevation change between -5 and +15 meters
    elevation = random.randint(-5, 15)
    
    # Advanced Running Metrics (Apple Watch)
    power = random.randint(150, 350) # Watts
    stride = round(random.uniform(0.8, 1.4), 2) # Meters
    
    return pace, cadence, hr, elevation, power, stride

def get_system_prompt():
    return """You are a friendly running coach giving immediate feedback. 
Based on the runner's current metrics, give ONE concise sentence of feedback or encouragement. Keep it conversational.
IMPORTANT: Respond ONLY with the spoken sentence. Do not use any <think> blocks, markdown formatting, or chain of thought reasoning."""

def generate_user_message(pace, cadence, hr, elevation, power, stride):
    """Builds just the data portion to send to the LLM."""
    return f"Current Metrics:\nHeart Rate: {hr} BPM\nPace: {pace}\nCadence: {cadence} steps per minute\nElevation Change: {elevation} meters\nRunning Power: {power} W\nStride Length: {stride} m"

def simulate_llm_response(chat_history):
    """
    Calls the REAL Gemma model locally on Linux via Ollama.
    Passes the entire conversational history.
    """
    import ollama
    try:
        start_time = time.perf_counter()
        response = ollama.chat(model='gemma4:e2b', messages=chat_history)
        llm_time = time.perf_counter() - start_time
        
        return {
            "text": response['message']['content'],
            "llm_time": llm_time,
            "prompt_tokens": response.get('prompt_eval_count', 0),
            "eval_tokens": response.get('eval_count', 0)
        }
    except Exception as e:
        return {
            "text": f"Error connecting to local Gemma: {e}",
            "llm_time": 0,
            "prompt_tokens": 0,
            "eval_tokens": 0
        }

def main():
    print("🏃‍♂️ Starting Running Coach Emulator (Terminal Edition)...")
    print("This script emulates the iOS LiveSession. It will trigger every 15 seconds.\n")
    
    # Statistics trackers
    total_llm_time = 0.0
    total_prompt_tokens = 0
    total_eval_tokens = 0
    run_count = 0
    
    # Initialize the Context Window (Memory)
    chat_history = [
        {'role': 'system', 'content': get_system_prompt()}
    ]
    
    try:
        while True:
            print("-" * 70)
            print("⏱️  [Timer fired: 15 seconds]")
            
            # 1. Gather Info
            sensor_start = time.perf_counter()
            pace, cadence, hr, elevation, power, stride = get_mock_sensor_data()
            sensor_time = time.perf_counter() - sensor_start
            
            print("\n📥 1. GATHERING SENSOR INFO (Emulated):")
            print(f"   - Heart Rate: {hr} BPM")
            print(f"   - GPS Pace: {pace}")
            print(f"   - Motion Cadence: {cadence} spm")
            print(f"   - Elevation Change: {elevation} meters")
            print(f"   - Running Power: {power} W")
            print(f"   - Stride Length: {stride} m")
            print(f"   ⏱️  Sensor data collected in: {sensor_time:.5f} seconds")
            
            # 2. Append to Context Window
            user_msg = generate_user_message(pace, cadence, hr, elevation, power, stride)
            chat_history.append({'role': 'user', 'content': user_msg})
            
            print("\n📝 2. NEW MESSAGE APPENDED TO CONTEXT:")
            print("\033[90m" + user_msg + "\033[0m") # Print in grey
            
            # 3. LLM Result
            print(f"🧠 3. LLM OUTPUT (Memory Size: {len(chat_history)} messages):")
            result_data = simulate_llm_response(chat_history)
            text_response = result_data["text"]
            
            # Save the coach's answer to the memory!
            chat_history.append({'role': 'assistant', 'content': text_response})
            
            # (Optional) Keep context window from growing infinitely to save memory
            if len(chat_history) > 11:
                # Remove the oldest user/assistant pair (index 1 and 2), keeping the system prompt at index 0
                chat_history.pop(1)
                chat_history.pop(1)
            
            print("\033[92m" + f"🗣️ Coach says: \"{text_response}\"" + "\033[0m") # Print in green
            
            # 4. Metrics & Averages
            if result_data["llm_time"] > 0:
                run_count += 1
                total_llm_time += result_data["llm_time"]
                total_prompt_tokens += result_data["prompt_tokens"]
                total_eval_tokens += result_data["eval_tokens"]
                
                print("\n📊 4. PERFORMANCE METRICS:")
                print(f"   - LLM Response Time: {result_data['llm_time']:.2f} seconds")
                print(f"   - Tokens Used: {result_data['prompt_tokens']} prompt + {result_data['eval_tokens']} generated")
                print(f"   - Speed: {(result_data['eval_tokens'] / result_data['llm_time']):.1f} tokens/sec")
                
                print(f"\n📈 RUNNING AVERAGES (Over {run_count} runs):")
                print(f"   - Avg LLM Time: {(total_llm_time / run_count):.2f} sec")
                print(f"   - Avg Prompt Tokens: {int(total_prompt_tokens / run_count)}")
                print(f"   - Avg Generated Tokens: {int(total_eval_tokens / run_count)}")
            
            print("-" * 70)
            print("Waiting 15 seconds for next update... (Press Ctrl+C to stop)")
            time.sleep(15)
            
    except KeyboardInterrupt:
        print("\nStopping emulator.")

if __name__ == "__main__":
    main()
