//
//  ContentView.swift
//  LibAVExtensionHost
//
//  Created by Anton Marini on 7/25/24.
//

import SwiftUI
import AVKit

struct ContentView: View {
    let asset:AVAsset
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    var body: some View {
        VStack {
            if isRunningTests {
                Text("Test mode: UI player disabled")
            } else {
                VideoPlayer(player: AVPlayer(playerItem: AVPlayerItem(asset: self.asset)))
            }
            
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(String(self.asset.duration.seconds))
        }
        .padding()
    }
}

#Preview {
    ContentView(asset: AVURLAsset(url: URL(filePath: "/Users/vade/Documents/Repositories/Fabric/FFMPEGMediaExtension/scripts/TestMedia/baseline_1920_1080_30fps_h264_aac.mkv"), options: [AVURLAssetPreferPreciseDurationAndTimingKey : true] ) )
}
