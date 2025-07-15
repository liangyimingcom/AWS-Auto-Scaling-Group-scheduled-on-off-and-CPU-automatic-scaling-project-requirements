#!/bin/bash

# CPU压力测试脚本 - 用于测试ASG自动扩缩容功能
# 使用方法: ./cpu-stress-test.sh [start|stop|status]

PROFILE="china"
REGION="cn-northwest-1"
ASG_NAME="ASG-POC-Group"

case "$1" in
    "start")
        echo "开始CPU压力测试..."
        echo "获取ASG中的实例..."
        
        # 获取ASG中的实例ID
        INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --profile $PROFILE \
            --region $REGION \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
            --output text)
        
        if [ -z "$INSTANCE_IDS" ]; then
            echo "未找到运行中的实例"
            exit 1
        fi
        
        echo "找到实例: $INSTANCE_IDS"
        
        # 为每个实例创建CPU压力测试命令
        for INSTANCE_ID in $INSTANCE_IDS; do
            echo "在实例 $INSTANCE_ID 上启动CPU压力测试..."
            
            # 使用Systems Manager发送命令
            aws ssm send-command \
                --instance-ids $INSTANCE_ID \
                --document-name "AWS-RunShellScript" \
                --parameters 'commands=["# 安装stress工具","sudo yum install -y stress","# 启动CPU压力测试（使用所有CPU核心）","nohup stress --cpu $(nproc) --timeout 600 > /tmp/stress.log 2>&1 &","echo \"CPU压力测试已启动，将运行10分钟\"","echo \"使用 top 命令查看CPU使用率\""]' \
                --profile $PROFILE \
                --region $REGION \
                --output table
        done
        
        echo "CPU压力测试已启动，预计10分钟后自动停止"
        echo "使用以下命令监控扩缩容活动:"
        echo "aws autoscaling describe-scaling-activities --auto-scaling-group-name $ASG_NAME --profile $PROFILE --region $REGION"
        ;;
        
    "stop")
        echo "停止CPU压力测试..."
        
        # 获取ASG中的实例ID
        INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --profile $PROFILE \
            --region $REGION \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
            --output text)
        
        if [ -z "$INSTANCE_IDS" ]; then
            echo "未找到运行中的实例"
            exit 1
        fi
        
        # 停止每个实例上的压力测试
        for INSTANCE_ID in $INSTANCE_IDS; do
            echo "在实例 $INSTANCE_ID 上停止CPU压力测试..."
            
            aws ssm send-command \
                --instance-ids $INSTANCE_ID \
                --document-name "AWS-RunShellScript" \
                --parameters 'commands=["# 停止stress进程","sudo pkill -f stress","echo \"CPU压力测试已停止\""]' \
                --profile $PROFILE \
                --region $REGION \
                --output table
        done
        ;;
        
    "status")
        echo "=== ASG状态监控 ==="
        
        # 显示ASG当前状态
        echo "1. ASG当前状态:"
        aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --profile $PROFILE \
            --region $REGION \
            --query 'AutoScalingGroups[0].{DesiredCapacity:DesiredCapacity,MinSize:MinSize,MaxSize:MaxSize,InstanceCount:length(Instances)}' \
            --output table
        
        # 显示实例状态
        echo "2. 实例状态:"
        aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --profile $PROFILE \
            --region $REGION \
            --query 'AutoScalingGroups[0].Instances[].{InstanceId:InstanceId,State:LifecycleState,Health:HealthStatus,AZ:AvailabilityZone}' \
            --output table
        
        # 显示最近的扩缩容活动
        echo "3. 最近的扩缩容活动:"
        aws autoscaling describe-scaling-activities \
            --auto-scaling-group-name $ASG_NAME \
            --max-items 5 \
            --profile $PROFILE \
            --region $REGION \
            --query 'Activities[].{Time:StartTime,Description:Description,Status:StatusCode,Cause:Cause}' \
            --output table
        
        # 显示CloudWatch告警状态
        echo "4. CloudWatch告警状态:"
        aws cloudwatch describe-alarms \
            --alarm-names "ASG-POC-CPU-High" "ASG-POC-CPU-Low" \
            --profile $PROFILE \
            --region $REGION \
            --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
            --output table 2>/dev/null || echo "告警可能不存在"
        
        # 显示CPU使用率（如果有实例运行）
        INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names $ASG_NAME \
            --profile $PROFILE \
            --region $REGION \
            --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
            --output text)
        
        if [ -n "$INSTANCE_IDS" ]; then
            echo "5. 当前CPU使用率:"
            for INSTANCE_ID in $INSTANCE_IDS; do
                echo "实例 $INSTANCE_ID:"
                # 使用兼容的日期格式
                START_TIME=$(date -u -v-10M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2025-07-15T00:50:00")
                END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
                
                aws cloudwatch get-metric-statistics \
                    --namespace AWS/EC2 \
                    --metric-name CPUUtilization \
                    --dimensions Name=InstanceId,Value=$INSTANCE_ID \
                    --start-time $START_TIME \
                    --end-time $END_TIME \
                    --period 300 \
                    --statistics Average \
                    --profile $PROFILE \
                    --region $REGION \
                    --query 'Datapoints[0].Average' \
                    --output text 2>/dev/null || echo "暂无数据"
            done
        fi
        ;;
        
    *)
        echo "使用方法: $0 [start|stop|status]"
        echo ""
        echo "命令说明:"
        echo "  start  - 在ASG中的所有实例上启动CPU压力测试"
        echo "  stop   - 停止ASG中所有实例上的CPU压力测试"
        echo "  status - 显示ASG状态和扩缩容活动"
        echo ""
        echo "注意:"
        echo "- 压力测试将持续10分钟后自动停止"
        echo "- 需要实例安装了SSM Agent"
        echo "- CPU使用率超过70%时会触发扩容"
        echo "- CPU使用率低于30%时会触发缩容"
        exit 1
        ;;
esac
