// OnboardingManager.swift
// Manages the conversational audio onboarding to extract user biometrics.

import Foundation

@MainActor
final class OnboardingManager: ObservableObject {
    @Published var isFinished: Bool = false
    @Published var extractedProfile: String = ""
    @Published var chatHistory: [(role: String, content: String)] = []
    
    private weak var engine: EngineModel?
    private weak var speaker: CoachSpeaker?
    
    private let onboardingPrompt = """
    You are a friendly running coach onboarding a new user. 
    Your goal is to collect exactly 3 pieces of information: their Age, their Height, and their Weight.
    Ask for one piece of information at a time in a conversational, friendly way. 
    If the user provides the information, acknowledge it and ask the next question.
    Once you have collected all 3 pieces of information, summarize what you learned in one sentence and then say exactly: 'We are ready to start running!'
    IMPORTANT: Keep your responses to one or two short spoken sentences. Do not use markdown.
    """
    
    func attach(engine: EngineModel, speaker: CoachSpeaker) {
        self.engine = engine
        self.speaker = speaker
    }
    
    /// Starts the conversational loop when the app first opens
    func startOnboarding() async {
        chatHistory = [
            (role: "system", content: onboardingPrompt),
            (role: "user", content: "Hi, I just opened the app for the first time.")
        ]
        await generateResponse()
    }
    
    /// should call this function when `SFSpeechRecognizer` transcribes the user's voice
    func processUserAudio(transcription: String) async {
        guard !isFinished else { return }
        chatHistory.append((role: "user", content: transcription))
        await generateResponse()
    }
    
    private func generateResponse() async {
        guard let engine = engine, engine.isReady else { return }
        
        var fullResponse = ""
        await engine.streamCoach(history: chatHistory, onChunk: { chunk in
            fullResponse += chunk
            self.speaker?.speak(chunk: chunk) // Streams audio to the user's headphones
        })
        
        chatHistory.append((role: "model", content: fullResponse))
        speaker?.flush()
        
        // State Machine transition check
        if fullResponse.lowercased().contains("ready to start running") || fullResponse.lowercased().contains("ready to run") {
            await extractFinalProfile()
        }
    }
    
    private func extractFinalProfile() async {
        guard let engine = engine, engine.isReady else { return }
        
        // Secretly append the extraction command
        chatHistory.append((role: "user", content: "System command: Summarize the user's age, height, and weight into one factual sentence."))
        
        var profile = ""
        // Generate the extraction SILENTLY (we don't pass it to the speaker)
        await engine.streamCoach(history: chatHistory, onChunk: { chunk in
            profile += chunk
        })
        
        self.extractedProfile = profile
        self.isFinished = true
    }
}
