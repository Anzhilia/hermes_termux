package com.nousresearch.hermes

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * ML Kit OCR 辅助类 — 从 control-app 移植
 *
 * 补充 AccessibilityService 无法获取的文字：
 * Canvas 绘制内容、WebView 内嵌文字、图片内文字等。
 */
object OcrHelper {

    private const val TAG = "OcrHelper"

    private val recognizer: TextRecognizer =
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())

    data class OcrBlock(
        val text: String,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
        val confidence: Float
    )

    /**
     * 从文件路径识别文字
     */
    fun recognizeFromFile(imagePath: String, timeoutMs: Long = 5000): List<OcrBlock> {
        val bitmap = BitmapFactory.decodeFile(imagePath)
        if (bitmap == null) {
            Log.e(TAG, "Failed to decode image: $imagePath")
            return emptyList()
        }
        return recognizeFromBitmap(bitmap, timeoutMs)
    }

    /**
     * 从 Bitmap 识别文字
     */
    fun recognizeFromBitmap(bitmap: Bitmap, timeoutMs: Long = 5000): List<OcrBlock> {
        val image = InputImage.fromBitmap(bitmap, 0)
        val latch = CountDownLatch(1)
        val results = mutableListOf<OcrBlock>()

        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                for (block in visionText.textBlocks) {
                    val box = block.boundingBox
                    if (box != null) {
                        val avgConfidence = block.lines.mapNotNull { it.confidence }
                            .average().let { if (it.isNaN()) 0.0 else it }

                        results.add(
                            OcrBlock(
                                text = block.text,
                                left = box.left,
                                top = box.top,
                                right = box.right,
                                bottom = box.bottom,
                                confidence = avgConfidence.toFloat()
                            )
                        )
                    }
                }
                Log.d(TAG, "OCR recognized ${results.size} blocks")
                latch.countDown()
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "OCR failed: ${e.message}", e)
                latch.countDown()
            }

        latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return results
    }

    /**
     * 将 OCR 结果转为 JSON 字符串
     */
    fun blocksToJsonString(blocks: List<OcrBlock>): String {
        val sb = StringBuilder("[")
        blocks.forEachIndexed { i, block ->
            if (i > 0) sb.append(",")
            sb.append("{")
            sb.append("\"text\":\"${escapeJson(block.text)}\",")
            sb.append("\"bounds\":\"[${block.left},${block.top}][${block.right},${block.bottom}]\",")
            sb.append("\"confidence\":${String.format("%.2f", block.confidence)}")
            sb.append("}")
        }
        sb.append("]")
        return sb.toString()
    }

    private fun escapeJson(s: String): String {
        return s.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }
}
