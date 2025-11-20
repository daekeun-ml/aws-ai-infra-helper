
#!/bin/bash

echo "=== FSx Performance Test ==="

echo "📁 FSx Mount Status:"
df -h | grep fsx
echo ""

echo "Timestamp: $(date)"
echo ""

echo "📝 Write Performance Test (1GB):"
echo "Starting write test..."
time sudo dd if=/dev/zero of=/fsx/testfile bs=1M count=1000 2>&1 | grep -E "(copied|MB/s|GB/s)"
echo ""

echo "📖 Read Performance Test:"
echo "Starting read test..."
time sudo dd if=/fsx/testfile of=/dev/null bs=1M 2>&1 | grep -E "(copied|MB/s|GB/s)"
echo ""

echo "📊 File Info:"
ls -lh /fsx/testfile
echo ""

echo "🧹 Cleaning up..."
sudo rm /fsx/testfile
echo "Test file removed."
echo ""

echo "✅ FSx Performance Test Complete!"
echo "Timestamp: $(date)"
