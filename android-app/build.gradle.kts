import java.util.Properties

plugins {
    id("com.android.application") version "8.5.0"
    id("org.jetbrains.kotlin.android") version "2.0.0"
}

// Release signing comes from keystore.properties (git-ignored, see README "Releases").
// Without it, assembleRelease still builds, just unsigned.
val releaseSigning = Properties().apply {
    rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
    namespace = "com.linkmymac.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.linkmymac.android"
        minSdk = 29
        targetSdk = 35
        versionCode = 2
        versionName = "1.1.0"
    }

    signingConfigs {
        if (!releaseSigning.isEmpty) {
            create("release") {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.google.zxing:core:3.5.3")
}
