# AWS Auto Scaling Group 定时开关机 POC

这个项目演示如何在AWS宁夏区域配置Auto Scaling Group实现EC2实例的定时开关机功能。

## 文件说明

- `ASG-AutoShutdown-POC.md` - 详细的配置文档，包含CLI和Console步骤
- `deploy-asg.sh` - 一键部署脚本
- `cleanup-asg.sh` - 资源清理脚本
- `verify-asg.sh` - 状态验证脚本
- `cpu-stress-test.sh` - CPU压力测试脚本，用于测试自动扩缩容
- `ec2-trust-policy.json` - EC2服务信任策略
- `autoscaling-trust-policy.json` - Auto Scaling服务信任策略

## 快速开始

### 1. 配置AWS CLI
```bash
aws configure --profile china
# 输入Access Key ID
# 输入Secret Access Key  
# 区域: cn-northwest-1
# 输出格式: json
```

### 2. 验证配置
```bash
aws sts get-caller-identity --profile china --region cn-northwest-1
```

### 3. 一键部署
```bash
./deploy-asg.sh
```

### 4. 验证部署
```bash
./verify-asg.sh
```

### 5. 测试CPU自动扩缩容
```bash
# 启动CPU压力测试
./cpu-stress-test.sh start

# 监控ASG状态和扩缩容活动
./cpu-stress-test.sh status

# 停止CPU压力测试
./cpu-stress-test.sh stop
```

### 6. 清理资源
```bash
./cleanup-asg.sh
```

## 功能特性

- **定时开机**: 每天早上9点UTC (北京时间17点)，启动2台实例
- **定时关机**: 每天晚上11点UTC (北京时间7点)，关闭所有实例
- **CPU自动扩缩容**: 开机时间段内基于CPU压力自动调整实例数量
  - 最小实例数: 2台（开机时间段）
  - 最大实例数: 6台
  - CPU > 70% 时自动扩容
  - CPU < 30% 时自动缩容（但不低于2台）
- **实例类型**: g4dn.xlarge (GPU实例)
- **健康检查**: EC2健康检查，300秒宽限期

## 时间说明

所有定时操作使用UTC时间：
- 关机: 23:00 UTC = 北京时间 07:00
- 开机: 09:00 UTC = 北京时间 17:00

如需调整时间，请修改Cron表达式：
```bash
# 关机时间调整为UTC 15:00 (北京时间23:00)
aws autoscaling put-scheduled-update-group-action \
  --scheduled-action-name "Shutdown-11PM" \
  --recurrence "0 15 * * *" \
  --desired-capacity 0

# 开机时间调整为UTC 01:00 (北京时间09:00)  
aws autoscaling put-scheduled-update-group-action \
  --scheduled-action-name "Startup-9AM" \
  --recurrence "0 1 * * *" \
  --desired-capacity 1
```

## 成本估算

g4dn.xlarge实例在宁夏区域的大概成本：
- 按需价格: ~$0.526/小时
- 基础运行（2台实例，14小时/天）: ~$14.73/天
- 高峰期扩容（最多6台）: 成本可能翻倍
- 预估月成本: $440-880/月（取决于CPU负载）

建议：
1. 考虑使用Spot实例降低成本
2. 评估是否真的需要GPU实例
3. 设置成本预算和告警
4. 监控CPU使用率，优化扩缩容阈值

## 故障排除

### 常见问题

1. **权限不足**
   - 确保IAM用户有足够权限
   - 检查服务关联角色

2. **实例启动失败**
   - 检查AMI ID是否正确
   - 验证安全组配置
   - 确认子网配置

3. **定时操作不执行**
   - 检查Cron表达式
   - 验证时区设置
   - 确认ASG状态

### 调试命令

```bash
# 查看ASG活动日志
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name ASG-POC-Group \
  --profile china --region cn-northwest-1

# 查看实例状态
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ASG-POC-Instance" \
  --profile china --region cn-northwest-1

# 手动触发扩缩容
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name ASG-POC-Group \
  --desired-capacity 1 \
  --profile china --region cn-northwest-1
```

## 安全注意事项

1. **网络安全**: 安全组默认开放SSH (22端口)，生产环境请限制源IP
2. **IAM权限**: 使用最小权限原则
3. **数据安全**: 实例关闭时数据会丢失，重要数据请存储在EBS或S3
4. **访问控制**: 建议使用AWS Systems Manager Session Manager代替SSH

## 监控建议

1. 设置CloudWatch告警监控ASG状态
2. 配置成本预算和告警
3. 监控实例健康状态
4. 记录扩缩容活动日志

## 支持

如有问题，请查看详细文档 `ASG-AutoShutdown-POC.md` 或联系管理员。
